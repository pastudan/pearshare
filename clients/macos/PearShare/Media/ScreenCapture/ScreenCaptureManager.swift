import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import OSLog

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
    private var currentConfig: SCStreamConfiguration?

    // Capture config
    var framesPerSecond: Double = 30
    var targetDisplay: SCDisplay?
    var targetWindow: SCWindow?
    /// Windows to exclude from capture (e.g. the RemoteCursorOverlayWindow).
    var excludedWindows: [SCWindow] = []

    /// Bundle IDs of apps whose windows should be blacked out in the capture stream.
    var excludedBundleIDs: [String] = []

    /// Window titles (exact match) to exclude — used to exclude overlay NSWindows by title.
    var excludedWindowTitles: [String] = []

    // MARK: - Available content

    /// Returns shareable displays and windows for the picker.
    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: - Start / Stop

    func startCapture(display: SCDisplay) async throws {
        self.targetDisplay = display

        // Resolve excluded apps (by bundle ID) and excluded overlay windows (by title).
        // Using excludingApplications:exceptingWindows: ensures ALL windows of excluded apps
        // are blacked out for the life of the stream, including ones opened after capture starts.
        let (excludedApps, excludedByTitle) = await resolveExcludedContent()
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
        // Title-matched windows (e.g. our own overlay) can't go through the app-level filter,
        // so we apply a second pass only if needed — swapping to window-exclusion mode.
        if excludedByTitle.isEmpty {
            try await startStream(with: filter)
        } else {
            // Title-matched windows exist (e.g. our overlay) — we can't mix app-level and
            // window-level exclusion in one filter, so fetch all windows for excluded apps
            // and combine them with the title-matched windows for a single window-exclusion filter.
            let bundleSet = Set(excludedApps.map(\.bundleIdentifier))
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
                try await startStream(with: filter)
                return
            }
            let appWindows = content.windows.filter {
                guard let b = $0.owningApplication?.bundleIdentifier else { return false }
                return bundleSet.contains(b)
            }
            var seen = Set<UInt32>()
            let allExcluded = (excludedByTitle + appWindows).filter { seen.insert($0.windowID).inserted }
            let fallbackFilter = SCContentFilter(display: display, excludingWindows: allExcluded)
            try await startStream(with: fallbackFilter)
        }
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
            currentConfig = nil
            delegate?.screenCaptureManagerDidStop(self)
        }
    }

    /// Dynamically toggle whether the system cursor is baked into the stream.
    /// On when host has control (viewer needs to see where host cursor is);
    /// off when viewer has control (viewer already knows their own cursor position).
    func setShowsCursor(_ show: Bool) {
        guard let stream, let config = currentConfig, config.showsCursor != show else { return }
        config.showsCursor = show
        stream.updateConfiguration(config) { error in
            if let error {
                Task { @MainActor in
                    Logger(subsystem: "com.pearshare.app", category: "ScreenCapture")
                        .error("setShowsCursor: \(error)")
                }
            }
        }
    }

    // MARK: - Internal

    /// Returns apps to exclude by bundle ID (for the application-level filter) and any
    /// windows to exclude by title (e.g. our overlay). Keeping these separate lets us use
    /// the application-level filter — which covers windows opened after capture starts —
    /// while still handling title-based exclusions.
    private func resolveExcludedContent() async -> (apps: [SCRunningApplication], titleWindows: [SCWindow]) {
        let titleSet  = Set(excludedWindowTitles)
        let bundleSet = Set(excludedBundleIDs)

        guard !titleSet.isEmpty || !bundleSet.isEmpty || !excludedWindows.isEmpty else {
            return ([], excludedWindows)
        }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return ([], excludedWindows)
        }

        let matchedApps = bundleSet.isEmpty ? [] : content.applications.filter {
            bundleSet.contains($0.bundleIdentifier)
        }

        var titleWindows = excludedWindows
        if !titleSet.isEmpty {
            titleWindows += content.windows.filter { titleSet.contains($0.title ?? "") }
        }

        return (matchedApps, titleWindows)
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
        config.showsCursor = true   // host has control at session start; will be toggled dynamically

        self.currentConfig = config
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
