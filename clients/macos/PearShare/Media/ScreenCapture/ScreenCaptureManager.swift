import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

// MARK: - Delegate

/// Called from ScreenCaptureKit's internal queue — implementors must be safe to call off main actor.
protocol ScreenCaptureManagerDelegate: AnyObject {
    func screenCaptureManager(_ manager: ScreenCaptureManager, didOutputSampleBuffer sampleBuffer: CMSampleBuffer)
    func screenCaptureManagerDidStop(_ manager: ScreenCaptureManager)
}

// MARK: - ScreenCaptureManager

/// Wraps ScreenCaptureKit to capture a display or window as a stream of CMSampleBuffers.
/// Requires Screen Recording permission (Privacy & Security → Screen Recording).
@MainActor
final class ScreenCaptureManager: NSObject {

    weak var delegate: ScreenCaptureManagerDelegate?

    private var stream: SCStream?
    private var streamOutput: StreamOutput?

    // Capture config
    var framesPerSecond: Double = 30
    var targetDisplay: SCDisplay?
    var targetWindow: SCWindow?
    /// Windows to exclude from capture (e.g. the RemoteCursorOverlayWindow).
    var excludedWindows: [SCWindow] = []

    /// Bundle IDs of apps whose windows should be blacked out in the capture stream.
    var excludedBundleIDs: [String] = []

    // MARK: - Available content

    /// Returns shareable displays and windows for the picker.
    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: - Start / Stop

    func startCapture(display: SCDisplay) async throws {
        self.targetDisplay = display

        // Collect windows belonging to excluded apps and pass them to the filter.
        // ScreenCaptureKit renders excluded windows as solid black rectangles.
        let excludedWindows = await resolveExcludedWindows()
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        try await startStream(with: filter)
    }

    func startCapture(window: SCWindow) async throws {
        self.targetWindow = window

        let filter = SCContentFilter(desktopIndependentWindow: window)
        try await startStream(with: filter)
    }

    func stopCapture() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
            streamOutput = nil
            delegate?.screenCaptureManagerDidStop(self)
        }
    }

    // MARK: - Internal

    /// Fetches all on-screen windows and returns those whose owning app bundle ID is excluded.
    private func resolveExcludedWindows() async -> [SCWindow] {
        guard !excludedBundleIDs.isEmpty else { return [] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return []
        }
        let excluded = Set(excludedBundleIDs)
        return content.windows.filter { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
            return excluded.contains(bundleID)
        }
    }

    private func startStream(with filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()

        // Resolution: capture at display's native resolution, scale down for performance
        if #available(macOS 14.0, *) {
            config.width = Int(filter.contentRect.width) > 0
                ? min(Int(filter.contentRect.width), 2560)
                : 1920
            config.height = Int(filter.contentRect.height) > 0
                ? min(Int(filter.contentRect.height), 1600)
                : 1080
        } else {
            config.width = 1920
            config.height = 1080
        }

        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        config.queueDepth = 3

        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = false
        config.showsCursor = true

        let output = StreamOutput()
        output.delegate = self
        self.streamOutput = output

        let s = SCStream(filter: filter, configuration: config, delegate: output)
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await s.startCapture()
        self.stream = s
    }
}

// MARK: - StreamOutput (SCStreamOutput + SCStreamDelegate)

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var delegate: ScreenCaptureManager?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard let d = delegate else { return }
        guard sampleBuffer.numSamples > 0 else { return }

        // Deliver directly — delegate protocol is explicitly off-main-actor safe
        Task { @MainActor in
            d.delegate?.screenCaptureManager(d, didOutputSampleBuffer: sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let d = delegate else { return }
        Task { @MainActor in
            d.delegate?.screenCaptureManagerDidStop(d)
        }
    }
}

// MARK: - Error

enum ScreenCaptureError: LocalizedError {
    case noDisplayAvailable
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable: return "No display available for capture."
        case .permissionDenied: return "Screen Recording permission is required."
        }
    }
}
