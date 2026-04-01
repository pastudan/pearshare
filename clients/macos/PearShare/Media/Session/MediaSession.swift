import Foundation
import Network
import CoreMedia
import CoreVideo
import CoreGraphics
import AppKit
import ScreenCaptureKit
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "MediaSession")

// MARK: - Shared tap log (tail -f /tmp/pearshare-tap.log)
// Internal (module-visible) so every file in the target can call tapLog() without re-defining it.
func tapLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/pearshare-tap.log"
    if FileManager.default.fileExists(atPath: path),
       let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Session Role

enum SessionRole {
    case host    // sharing screen, receiving input
    case viewer  // viewing remote screen, sending input
}

// MARK: - MediaSession

/// Owns the full media pipeline for one active PearShare session.
///
/// Host path:   ScreenCaptureKit → VideoEncoder (HEVC) → RTPPacketizer → UDP socket
/// Viewer path: UDP socket → RTPDepacketizer → VideoDecoder (HEVC) → VideoRenderer → MTKView
@MainActor
final class MediaSession: NSObject {

    let descriptor: SessionDescriptor
    let role: SessionRole
    // nonisolated(unsafe) because enqueue() is thread-safe (uses bufferLock internally)
    // and we want to call it directly from the VT decode callback without a MainActor hop.
    nonisolated(unsafe) let renderer: VideoRenderer?   // non-nil when role == .viewer

    let debugInfo = SessionDebugInfo()

    private var captureManager: ScreenCaptureManager?
    // Exposed so AppDelegate can attach cursor/activity callbacks after start()
    private(set) var controlChannel: ControlChannel?
    nonisolated(unsafe) private var decoder: VideoDecoder?
    nonisolated(unsafe) private var depacketizer: RTPDepacketizer?
    private var videoRecvListener: NWListener?

    // These are accessed from nonisolated callbacks on the hot path — stored as nonisolated
    // references so we don't pay the MainActor hop for every encoded frame.
    nonisolated(unsafe) private var encoder: VideoEncoder?
    nonisolated(unsafe) private var hasLoggedFirstSCKFrame = false
    nonisolated(unsafe) private var hasUpdatedDecodedDims  = false
    nonisolated(unsafe) private var packetizer: RTPPacketizer?
    nonisolated(unsafe) private var videoSendConnection: NWConnection?

    // Viewer-side watchdog: tracks the last received I-frame and requests a new keyframe
    // if the stream goes stale. nonisolated(unsafe) because it's written from the VT
    // decode callback queue and read on the main actor timer queue.
    nonisolated(unsafe) private var lastKeyframeDate: Date?
    private var videoWatchdogTimer: Timer?
    private static let keyframeStalenessThreshold: TimeInterval = 8   // request keyframe
    private static let videoFrozenThreshold:       TimeInterval = 20  // reset decoder too

    var onStop: (() -> Void)?
    /// Window titles to exclude from screen capture (cursor overlay windows).
    var overlayWindowTitles: [String] = []

    /// Toggle whether the system cursor is baked into the H.264 stream.
    func setShowsCursor(_ show: Bool) { captureManager?.setShowsCursor(show) }

    // MARK: - Init

    init(descriptor: SessionDescriptor, role: SessionRole) {
        self.descriptor = descriptor
        self.role = role
        self.renderer = role == .viewer ? VideoRenderer.make() : nil
        super.init()
    }

    // MARK: - Start

    func start() async throws {
        switch role {
        case .host:
            try await startHostPipeline()
        case .viewer:
            try startViewerPipeline()
        }
    }

    // MARK: - Host pipeline: capture → encode → send

    private func startHostPipeline() async throws {
        let content = try await ScreenCaptureManager.availableContent()
        guard let display = content.displays.first else {
            throw MediaSessionError.noDisplayAvailable
        }

        // Physical pixel dimensions — NSScreen.backingScaleFactor × frame is the most reliable
        // source: CGDisplayPixelsWide can return the logical point count (half resolution) on
        // some Retina/HiDPI configurations. SCDisplay.width/height are always logical points.
        let matchingScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
        let physWidth: Int
        let physHeight: Int
        if let screen = matchingScreen {
            let scale = screen.backingScaleFactor
            physWidth  = Int(screen.frame.width  * scale)
            physHeight = Int(screen.frame.height * scale)
        } else {
            let physW = CGDisplayPixelsWide(display.displayID)
            let physH = CGDisplayPixelsHigh(display.displayID)
            physWidth  = physW > 0 ? physW : display.width
            physHeight = physH > 0 ? physH : display.height
        }
        logger.info("Host: display \(physWidth)×\(physHeight) px (SCDisplay: \(display.width)×\(display.height) pts)")
        tapLog("[HOST-1] SCDisplay logical=\(display.width)×\(display.height) pts  |  NSScreen physical=\(physWidth)×\(physHeight) px  |  displayID=\(display.displayID)  |  matchedNSScreen=\(matchingScreen != nil)")

        // Encode at native physical resolution. Apple Silicon hardware HEVC handles
        // ultrawide and HiDPI displays (3440×1440, 5K, etc.) without issue.
        // Dimensions must be even numbers as required by the video codec.
        let encWidth  = (physWidth  + 1) & ~1
        let encHeight = (physHeight + 1) & ~1
        tapLog("[HOST-1b] Encode size (native): \(encWidth)×\(encHeight) px")

        let enc = VideoEncoder()
        enc.delegate = self
        enc.frameRate = 15
        try enc.prepare(width: encWidth, height: encHeight)
        self.encoder = enc
        tapLog("[HOST-2] Encoder prepared: \(encWidth)×\(encHeight) px  |  fps=\(enc.frameRate)  |  uncapped bitrate")
        logger.info("Host: encoder ready at \(encWidth)×\(encHeight)")

        debugInfo.setStreamInfo(
            encodeWidth: encWidth, encodeHeight: encHeight,
            physicalWidth: physWidth, physicalHeight: physHeight,
            targetFPS: enc.frameRate,
            targetBitrateMbps: 0
        )
        debugInfo.start()

        self.packetizer = RTPPacketizer(streamID: kPearStreamVideo)

        let conn = NWConnection(
            host: NWEndpoint.Host(descriptor.peerIP),
            port: NWEndpoint.Port(rawValue: UInt16(descriptor.videoPort))!,
            using: .udp
        )
        conn.stateUpdateHandler = { state in
            logger.info("Host: UDP conn state → \(String(describing: state))")
        }
        conn.start(queue: .global(qos: .userInteractive))
        self.videoSendConnection = conn

        // Control channel: host side listens for remote input events
        let ctrl = ControlChannel(role: .host, port: descriptor.controlPort, peerIP: nil)
        ctrl.onKeyframeRequested = { [weak self] in
            self?.encoder?.forceNextKeyframe()
        }
        ctrl.start()
        self.controlChannel = ctrl
        logger.info("Host: control channel listening on port \(self.descriptor.controlPort)")

        let capture = ScreenCaptureManager()
        capture.delegate = self
        capture.framesPerSecond = 15
        capture.excludedBundleIDs = ExcludedAppsStore.shared.enabledBundleIDs
        capture.excludedWindowTitles = overlayWindowTitles
        // Tell SCKit to deliver pixel buffers at the capped encode size, not native resolution.
        // Tell SCKit to deliver pixel buffers at native resolution.
        capture.outputSize = CGSize(width: encWidth, height: encHeight)
        try await capture.startCapture(display: display)
        self.captureManager = capture
        logger.info("Host: capture started")
    }

    // MARK: - Viewer pipeline: receive → decode → render

    private func startViewerPipeline() throws {
        logger.info("Viewer: starting pipeline, listening on port \(self.descriptor.videoPort)")

        // Control channel: viewer side captures events and sends to host
        let ctrl = ControlChannel(role: .viewer, port: descriptor.controlPort, peerIP: descriptor.peerIP)
        ctrl.start()
        self.controlChannel = ctrl
        logger.info("Viewer: control channel sending to \(self.descriptor.peerIP):\(self.descriptor.controlPort)")

        let depkt = RTPDepacketizer(streamID: kPearStreamVideo)
        depkt.onFrame = { [weak self] frame in
            self?.handleReassembledFrame(frame)
        }
        self.depacketizer = depkt

        let dec = VideoDecoder()
        dec.delegate = self
        dec.onDecodeError = { [weak self] in
            // Called on VT decode queue — hop to MainActor to send the control message.
            Task { @MainActor [weak self] in
                guard let self else { return }
                tapLog("[VIEWER-ERR] Decode error — requesting keyframe")
                self.controlChannel?.sendRequestKeyframe()
            }
        }
        self.decoder = dec

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(
            using: params,
            on: NWEndpoint.Port(rawValue: UInt16(descriptor.videoPort))!
        ) else {
            throw MediaSessionError.bindFailed
        }

        listener.stateUpdateHandler = { state in
            logger.info("Viewer: listener state → \(String(describing: state))")
        }

        listener.newConnectionHandler = { [weak self] conn in
            logger.info("Viewer: got UDP connection from \(String(describing: conn.endpoint))")
            conn.start(queue: .global(qos: .userInteractive))
            self?.receiveVideoPackets(from: conn)
        }
        listener.start(queue: .global(qos: .userInteractive))
        self.videoRecvListener = listener
        logger.info("Viewer: listener started on port \(self.descriptor.videoPort)")

        debugInfo.setStreamInfo(
            encodeWidth: 0, encodeHeight: 0,
            physicalWidth: 0, physicalHeight: 0,
            targetFPS: 0,
            targetBitrateMbps: 0
        )
        debugInfo.start()
        startVideoWatchdog()
    }

    // MARK: - Video watchdog

    private func startVideoWatchdog() {
        videoWatchdogTimer?.invalidate()
        lastKeyframeDate = nil
        videoWatchdogTimer = Timer.scheduledTimer(
            withTimeInterval: Self.keyframeStalenessThreshold / 2,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkVideoHealth() }
        }
    }

    private func checkVideoHealth() {
        guard role == .viewer else { return }
        let now = Date()
        guard let last = lastKeyframeDate else {
            // No keyframe received yet since session start — request one
            tapLog("[VIEWER-WATCHDOG] No keyframe since session start — requesting")
            controlChannel?.sendRequestKeyframe()
            return
        }
        let age = now.timeIntervalSince(last)
        if age >= Self.videoFrozenThreshold {
            // Long freeze: reset the decoder to clear any corrupted state, then ask for keyframe
            tapLog("[VIEWER-WATCHDOG] No keyframe for \(Int(age))s — resetting decoder + requesting keyframe")
            decoder?.invalidate()
            controlChannel?.sendRequestKeyframe()
        } else if age >= Self.keyframeStalenessThreshold {
            tapLog("[VIEWER-WATCHDOG] No keyframe for \(Int(age))s — requesting keyframe")
            controlChannel?.sendRequestKeyframe()
        }
    }

    // MARK: - Stop

    func stop() {
        videoWatchdogTimer?.invalidate()
        videoWatchdogTimer = nil
        debugInfo.stop()
        captureManager?.stopCapture()
        controlChannel?.stop()
        controlChannel = nil
        encoder?.flush()
        encoder?.invalidate()
        decoder?.invalidate()
        videoSendConnection?.cancel()
        videoRecvListener?.cancel()
        captureManager = nil
        encoder = nil
        decoder = nil
        packetizer = nil
        depacketizer = nil
        videoSendConnection = nil
        videoRecvListener = nil
        onStop?()
    }

    // MARK: - Video receive loop

    nonisolated private func receiveVideoPackets(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                logger.error("Viewer: receive error \(error)")
                // NWError.posix(.ECANCELED) means we intentionally cancelled — stop the loop.
                // Any other error is treated as transient; keep looping so a resumed stream
                // (e.g. host briefly paused) doesn't permanently silence the receiver.
                if case .posix(let code) = error, code == .ECANCELED { return }
            } else if let data {
                self.debugInfo.recordBytes(data.count)
                self.depacketizer?.receive(packet: data)
            }
            self.receiveVideoPackets(from: connection)
        }
    }

    nonisolated private func handleReassembledFrame(_ frame: RTPDepacketizer.ReassembledFrame) {
        if frame.isKeyframe { lastKeyframeDate = Date() }
        decoder?.decode(annexBData: frame.nalUnit, isKeyframe: frame.isKeyframe)
    }
}

// MARK: - ScreenCaptureManagerDelegate (host)

extension MediaSession: ScreenCaptureManagerDelegate {
    nonisolated func screenCaptureManager(_ manager: ScreenCaptureManager, didOutputSampleBuffer sampleBuffer: CMSampleBuffer) {
        if !hasLoggedFirstSCKFrame, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            hasLoggedFirstSCKFrame = true
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            tapLog("[HOST-3] First SCK pixel buffer delivered: \(w)×\(h) px  (requested config.width/height above)")
        }
        encoder?.encode(sampleBuffer: sampleBuffer)
    }

    nonisolated func screenCaptureManagerDidStop(_ manager: ScreenCaptureManager) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - VideoEncoderDelegate (host)

extension MediaSession: VideoEncoderDelegate {
    nonisolated func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnit data: Data, isKeyframe: Bool, presentationTimestamp: CMTime) {
        guard let pktz = packetizer,
              let conn = videoSendConnection else { return }

        debugInfo.recordFrame()
        debugInfo.recordBytes(data.count)

        let packets = pktz.packetize(nalUnit: data, isKeyframe: isKeyframe, presentationTimestamp: presentationTimestamp)
        if isKeyframe { logger.info("Host: sending keyframe, \(packets.count) RTP packets, \(data.count) bytes") }
        for packet in packets {
            conn.send(content: packet, completion: .idempotent)
        }
    }
}

// MARK: - VideoDecoderDelegate (viewer)

extension MediaSession: VideoDecoderDelegate {
    nonisolated func videoDecoder(_ decoder: VideoDecoder, didDecodeFrame pixelBuffer: CVPixelBuffer, presentationTimestamp: CMTime) {
        // renderer.enqueue() is thread-safe (internal NSLock), so call directly on the
        // VT decode callback queue — no MainActor hop needed for every frame.
        renderer?.enqueue(pixelBuffer: pixelBuffer)
        debugInfo.recordFrame()
        if !hasUpdatedDecodedDims {
            hasUpdatedDecodedDims = true
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            Task { @MainActor [weak self] in self?.debugInfo.updateStreamDimensions(width: w, height: h) }
        }
    }
}
// MARK: - Error

enum MediaSessionError: LocalizedError {
    case noDisplayAvailable
    case bindFailed

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable: return "No display found to capture."
        case .bindFailed:         return "Failed to bind media receive port."
        }
    }
}
