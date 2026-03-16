import Foundation
import Network
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "MediaSession")

// MARK: - Session Role

enum SessionRole {
    case host    // sharing screen, receiving input
    case viewer  // viewing remote screen, sending input
}

// MARK: - MediaSession

/// Owns the full media pipeline for one active PearShare session.
///
/// Host path:   ScreenCaptureKit → H264Encoder → RTPPacketizer → UDP socket
/// Viewer path: UDP socket → RTPDepacketizer → H264Decoder → VideoRenderer → MTKView
@MainActor
final class MediaSession: NSObject {

    let descriptor: SessionDescriptor
    let role: SessionRole
    let renderer: VideoRenderer?   // non-nil when role == .viewer

    private var captureManager: ScreenCaptureManager?
    // Exposed so AppDelegate can attach cursor/activity callbacks after start()
    private(set) var controlChannel: ControlChannel?
    nonisolated(unsafe) private var decoder: H264Decoder?
    nonisolated(unsafe) private var depacketizer: RTPDepacketizer?
    private var videoRecvListener: NWListener?

    // These are accessed from nonisolated callbacks on the hot path — stored as nonisolated
    // references so we don't pay the MainActor hop for every encoded frame.
    nonisolated(unsafe) private var encoder: H264Encoder?
    nonisolated(unsafe) private var packetizer: RTPPacketizer?
    nonisolated(unsafe) private var videoSendConnection: NWConnection?

    var onStop: (() -> Void)?
    /// Window title to exclude from screen capture (the remote cursor overlay).
    var overlayWindowTitle: String?

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
        logger.info("Host: display \(display.width)x\(display.height), sending to \(self.descriptor.peerIP):\(self.descriptor.videoPort)")

        let enc = H264Encoder()
        enc.delegate = self
        enc.frameRate = 30
        try enc.prepare(width: display.width, height: display.height)
        self.encoder = enc
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
        capture.framesPerSecond = 30
        capture.excludedBundleIDs = ExcludedAppsStore.shared.enabledBundleIDs
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

        let dec = H264Decoder()
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
            let line = "\(Date()) [MediaSession] Viewer: received UDP \(data.count) bytes\n"
            if let d = line.data(using: .utf8) {
                let path = "/tmp/pearshare-decoder.log"
                if FileManager.default.fileExists(atPath: path),
                   let fh = FileHandle(forWritingAtPath: path) {
                    fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
                } else { try? d.write(to: URL(fileURLWithPath: path)) }
            }
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
        encoder?.encode(sampleBuffer: sampleBuffer)
    }

    nonisolated func screenCaptureManagerDidStop(_ manager: ScreenCaptureManager) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - H264EncoderDelegate (host)

extension MediaSession: H264EncoderDelegate {
    nonisolated func h264Encoder(_ encoder: H264Encoder, didEncodeNALUnit data: Data, isKeyframe: Bool, presentationTimestamp: CMTime) {
        guard let pktz = packetizer,
              let conn = videoSendConnection else { return }

        let packets = pktz.packetize(nalUnit: data, isKeyframe: isKeyframe, presentationTimestamp: presentationTimestamp)
        if isKeyframe { logger.info("Host: sending keyframe, \(packets.count) RTP packets, \(data.count) bytes") }
        for packet in packets {
            conn.send(content: packet, completion: .idempotent)
        }
    }
}

// MARK: - H264DecoderDelegate (viewer)

extension MediaSession: H264DecoderDelegate {
    nonisolated func h264Decoder(_ decoder: H264Decoder, didDecodeFrame pixelBuffer: CVPixelBuffer, presentationTimestamp: CMTime) {
        logger.info("Viewer: decoded frame, enqueueing to renderer")
        renderer?.enqueue(pixelBuffer: pixelBuffer)
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
