import Foundation
import Network
import CoreMedia
import CoreVideo
import CoreGraphics
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
    let renderer: VideoRenderer?   // non-nil when role == .viewer

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
    nonisolated(unsafe) private var packetizer: RTPPacketizer?
    nonisolated(unsafe) private var videoSendConnection: NWConnection?

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

        // Physical pixel dimensions — SCDisplay.width/height are logical points, which gives
        // half-resolution on Retina displays. CoreGraphics returns the true pixel count.
        let physW = CGDisplayPixelsWide(display.displayID)
        let physH = CGDisplayPixelsHigh(display.displayID)
        let captureWidth  = physW > 0 ? physW : display.width
        let captureHeight = physH > 0 ? physH : display.height
        logger.info("Host: display \(captureWidth)×\(captureHeight) px (SCDisplay: \(display.width)×\(display.height) pts)")
        tapLog("[HOST-1] SCDisplay logical=\(display.width)×\(display.height) pts  |  CGDisplay physical=\(physW)×\(physH) px  |  displayID=\(display.displayID)")

        let enc = VideoEncoder()
        enc.delegate = self
        enc.frameRate = 15
        try enc.prepare(width: captureWidth, height: captureHeight)
        self.encoder = enc
        tapLog("[HOST-2] Encoder prepared: \(captureWidth)×\(captureHeight) px  |  fps=\(enc.frameRate)  |  bitrate=\(enc.targetBitrate/1_000_000) Mbps")
        logger.info("Host: encoder ready")

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
        ctrl.start()
        self.controlChannel = ctrl
        logger.info("Host: control channel listening on port \(self.descriptor.controlPort)")

        let capture = ScreenCaptureManager()
        capture.delegate = self
        capture.framesPerSecond = 15
        capture.excludedBundleIDs = ExcludedAppsStore.shared.enabledBundleIDs
        capture.excludedWindowTitles = overlayWindowTitles
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
    }

    // MARK: - Stop

    func stop() {
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
            if let error { logger.error("Viewer: receive error \(error)"); return }
            guard let data else { return }
            self.depacketizer?.receive(packet: data)
            self.receiveVideoPackets(from: connection)
        }
    }

    nonisolated private func handleReassembledFrame(_ frame: RTPDepacketizer.ReassembledFrame) {
        logger.info("Viewer: reassembled frame \(frame.nalUnit.count) bytes, keyframe=\(frame.isKeyframe)")
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
        logger.info("Viewer: decoded frame, enqueueing to renderer")
        Task { @MainActor in
            renderer?.enqueue(pixelBuffer: pixelBuffer)
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
