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

    /// Override the SCStream output resolution (pixel dimensions). When set, SCKit scales the
    /// captured display down to this size before delivering pixel buffers — the encoder and
    /// viewer both work at this resolution rather than the display's native resolution.
    /// Leave nil to use the physical display resolution (not recommended for large/ultrawide displays).
    var outputSize: CGSize?

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

        // Prefer an explicit outputSize (caller has already applied any resolution cap).
        // Fall back to physical pixel dimensions via CoreGraphics — SCDisplay.width/height
        // are logical points, which gives half-resolution on Retina displays.
        if let size = outputSize {
            config.width  = Int(size.width)
            config.height = Int(size.height)
            tapLog("[HOST-2b] SCStreamConfig (capped): \(config.width)×\(config.height)")
        } else if let display = targetDisplay {
            let physW = CGDisplayPixelsWide(display.displayID)
            let physH = CGDisplayPixelsHigh(display.displayID)
            config.width  = physW > 0 ? physW : 2560
            config.height = physH > 0 ? physH : 1600
            let rectDesc: String
            if #available(macOS 14.0, *) {
                rectDesc = "\(Int(filter.contentRect.width))×\(Int(filter.contentRect.height)) pts"
            } else {
                rectDesc = "n/a (<macOS14)"
            }
            tapLog("[HOST-2b] SCStreamConfig (native): width=\(config.width) height=\(config.height)  |  CGDisplay=\(physW)×\(physH)  |  contentRect=\(rectDesc)")
        } else {
            config.width  = 2560
            config.height = 1600
            tapLog("[HOST-2b] SCStreamConfig fallback (no targetDisplay): \(config.width)×\(config.height)")
        }

        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        config.queueDepth = 5   // slightly deeper queue to absorb keyframe spikes

        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = false
        config.showsCursor = true   // host has control at session start; will be toggled dynamically

        self.currentConfig = config

        // Store a capture callback at @MainActor time so StreamOutput can invoke the
        // nonisolated delegate method directly on SCKit's queue — no actor-hop per frame.
        let captureCallback = makeFrameCallback()
        let output = StreamOutput(onFrame: captureCallback, owner: self)
        self.streamOutput = output

        let s = SCStream(filter: filter, configuration: config, delegate: output)
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await s.startCapture()
        self.stream = s
    }

    /// Builds a closure that calls the delegate's nonisolated frame method directly from
    /// SCKit's delivery queue, avoiding the Task { @MainActor } hop on every frame.
    private func makeFrameCallback() -> (CMSampleBuffer) -> Void {
        // Capture weak refs at @MainActor time; the closure itself has no actor requirement.
        weak let weakSelf = self
        weak let weakDelegate = delegate as AnyObject
        return { sampleBuffer in
            guard let manager = weakSelf,
                  let del = weakDelegate as? ScreenCaptureManagerDelegate else { return }
            del.screenCaptureManager(manager, didOutputSampleBuffer: sampleBuffer)
        }
    }
}

// MARK: - StreamOutput (SCStreamOutput + SCStreamDelegate)

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    // Called directly on SCKit's queue — no actor hop.
    private let onFrame: (CMSampleBuffer) -> Void
    // Weak back-reference used only for the stop notification (needs @MainActor hop).
    weak var owner: ScreenCaptureManager?

    init(onFrame: @escaping (CMSampleBuffer) -> Void, owner: ScreenCaptureManager) {
        self.onFrame = onFrame
        self.owner = owner
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.numSamples > 0 else { return }
        // Invoke directly — no actor hop, no Task allocation per frame.
        onFrame(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let owner else { return }
        Task { @MainActor in
            owner.delegate?.screenCaptureManagerDidStop(owner)
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
