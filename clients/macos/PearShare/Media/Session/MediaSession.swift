import Foundation
import Network
import CoreMedia
import CoreVideo
import ScreenCaptureKit

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
    nonisolated(unsafe) private var decoder: H264Decoder?
    nonisolated(unsafe) private var depacketizer: RTPDepacketizer?
    private var videoRecvListener: NWListener?

    // These are accessed from nonisolated callbacks on the hot path — stored as nonisolated
    // references so we don't pay the MainActor hop for every encoded frame.
    nonisolated(unsafe) private var encoder: H264Encoder?
    nonisolated(unsafe) private var packetizer: RTPPacketizer?
    nonisolated(unsafe) private var videoSendConnection: NWConnection?

    var onStop: (() -> Void)?

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
        // 1. Pick the primary display
        let content = try await ScreenCaptureManager.availableContent()
        guard let display = content.displays.first else {
            throw MediaSessionError.noDisplayAvailable
        }

        // 2. Set up encoder
        let enc = H264Encoder()
        enc.delegate = self
        enc.frameRate = 30
        try enc.prepare(width: display.width, height: display.height)
        self.encoder = enc

        // 3. Set up packetizer
        self.packetizer = RTPPacketizer(streamID: kPearStreamVideo)

        // 4. Open UDP send socket to viewer's video port
        let conn = NWConnection(
            host: NWEndpoint.Host(descriptor.peerIP),
            port: NWEndpoint.Port(rawValue: UInt16(descriptor.videoPort))!,
            using: .udp
        )
        conn.start(queue: .global(qos: .userInteractive))
        self.videoSendConnection = conn

        // 5. Start capture
        let capture = ScreenCaptureManager()
        capture.delegate = self
        capture.framesPerSecond = 30
        try await capture.startCapture(display: display)
        self.captureManager = capture
    }

    // MARK: - Viewer pipeline: receive → decode → render

    private func startViewerPipeline() throws {
        // 1. Set up depacketizer
        let depkt = RTPDepacketizer(streamID: kPearStreamVideo)
        depkt.onFrame = { [weak self] frame in
            self?.handleReassembledFrame(frame)
        }
        self.depacketizer = depkt

        // 2. Set up decoder
        let dec = H264Decoder()
        dec.delegate = self
        self.decoder = dec

        // 3. Listen on our video port for incoming RTP packets
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(
            using: params,
            on: NWEndpoint.Port(rawValue: UInt16(descriptor.videoPort))!
        ) else {
            throw MediaSessionError.bindFailed
        }

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            self?.receiveVideoPackets(from: conn)
        }
        listener.start(queue: .global(qos: .userInteractive))
        self.videoRecvListener = listener
    }

    // MARK: - Stop

    func stop() {
        captureManager?.stopCapture()
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
            guard let self, error == nil, let data else { return }
            self.depacketizer?.receive(packet: data)
            self.receiveVideoPackets(from: connection)
        }
    }

    nonisolated private func handleReassembledFrame(_ frame: RTPDepacketizer.ReassembledFrame) {
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
        for packet in packets {
            conn.send(content: packet, completion: .idempotent)
        }
    }
}

// MARK: - H264DecoderDelegate (viewer)

extension MediaSession: H264DecoderDelegate {
    nonisolated func h264Decoder(_ decoder: H264Decoder, didDecodeFrame pixelBuffer: CVPixelBuffer, presentationTimestamp: CMTime) {
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
