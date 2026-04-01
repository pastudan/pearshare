import Foundation
import CoreMedia

// MARK: - Packet header layout (12 bytes)
//
//  0       1       2       3
//  +-------+-------+-------+-------+
//  | ver   | strid |   seqnum      |
//  +-------+-------+-------+-------+
//  |           timestamp           |
//  +-------+-------+-------+-------+
//  | flags | reserved              |
//  +-------+-------+-------+-------+
//
// ver:       UInt8  — always 1
// strid:     UInt8  — stream ID: 1=video, 2=audio, 3=control
// seqnum:    UInt16 — big-endian, per-stream, wraps at 65535
// timestamp: UInt32 — big-endian, microseconds since session start
// flags:     UInt8  — 0x01=keyframe, 0x02=last-packet-of-frame, 0x04=retransmit
// reserved:  3 bytes

let kPearPacketHeaderSize = 12
let kPearStreamVideo:   UInt8 = 1
let kPearStreamAudio:   UInt8 = 2
let kPearStreamControl: UInt8 = 3

struct PearPacketHeader {
    let version: UInt8
    let streamID: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let flags: UInt8

    static let keyframeMask:   UInt8 = 0x01
    static let lastPacketMask: UInt8 = 0x02
    static let retransmitMask: UInt8 = 0x04

    var isKeyframe:   Bool { flags & Self.keyframeMask   != 0 }
    var isLastPacket: Bool { flags & Self.lastPacketMask != 0 }
    var isRetransmit: Bool { flags & Self.retransmitMask != 0 }
}

// MARK: - RTPPacketizer

/// Splits a NAL unit into MTU-sized UDP packets with PearPacket headers.
final class RTPPacketizer {

    /// Maximum UDP payload bytes (Tailscale WireGuard MTU is 1280; leave headroom)
    static let maxPayloadSize = 1200

    private var sequenceNumber: UInt16 = 0
    private let streamID: UInt8
    private let sessionStartMicros: UInt64

    init(streamID: UInt8 = kPearStreamVideo) {
        self.streamID = streamID
        self.sessionStartMicros = Self.nowMicros()
    }

    /// Packetizes `nalUnit` into one or more `Data` packets ready to send over UDP.
    func packetize(nalUnit: Data, isKeyframe: Bool, presentationTimestamp: CMTime? = nil) -> [Data] {
        let timestamp = Self.nowMicros() - sessionStartMicros
        let tsMicros = UInt32(min(timestamp, UInt64(UInt32.max)))

        var packets: [Data] = []
        var offset = 0

        while offset < nalUnit.count {
            let remaining = nalUnit.count - offset
            let chunkSize = min(remaining, Self.maxPayloadSize)
            let isLast = (offset + chunkSize) >= nalUnit.count

            var flags: UInt8 = 0
            if isKeyframe && offset == 0 { flags |= PearPacketHeader.keyframeMask }
            if isLast                    { flags |= PearPacketHeader.lastPacketMask }

            let header = makeHeader(
                seqNum: nextSeqNum(),
                timestamp: tsMicros,
                flags: flags
            )
            var packet = header
            packet.append(nalUnit[offset ..< offset + chunkSize])
            packets.append(packet)

            offset += chunkSize
        }

        return packets
    }

    // MARK: - Private

    private func nextSeqNum() -> UInt16 {
        defer { sequenceNumber &+= 1 }
        return sequenceNumber
    }

    private func makeHeader(seqNum: UInt16, timestamp: UInt32, flags: UInt8) -> Data {
        var data = Data(count: kPearPacketHeaderSize)
        data[0] = 1           // version
        data[1] = streamID
        data[2] = UInt8(seqNum >> 8)
        data[3] = UInt8(seqNum & 0xFF)
        data[4] = UInt8((timestamp >> 24) & 0xFF)
        data[5] = UInt8((timestamp >> 16) & 0xFF)
        data[6] = UInt8((timestamp >>  8) & 0xFF)
        data[7] = UInt8( timestamp        & 0xFF)
        data[8] = flags
        // bytes 9-11: reserved, already zero
        return data
    }

    static func nowMicros() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom)
        return nanos / 1000
    }
}

// MARK: - RTPDepacketizer

/// Reassembles UDP packets back into complete NAL units, with simple jitter buffering.
final class RTPDepacketizer {

    struct ReassembledFrame {
        let nalUnit: Data
        let isKeyframe: Bool
        let timestamp: UInt32
    }

    /// Called when a complete NAL unit has been reassembled.
    var onFrame: ((ReassembledFrame) -> Void)?

    private let streamID: UInt8
    private var fragments: [UInt32: Data] = [:]  // timestamp → accumulated NAL bytes
    private var frameIsKeyframe: [UInt32: Bool] = [:]
    private var lastDeliveredTimestamp: UInt32 = 0

    // Jitter buffer: hold up to 4 frames before forcing delivery of the oldest
    private var pendingTimestamps: [UInt32] = []
    private let jitterBufferDepth = 3

    // Sequence number tracking for gap detection
    private var expectedSequenceNumber: UInt16?

    init(streamID: UInt8 = kPearStreamVideo) {
        self.streamID = streamID
    }

    /// Feed a raw UDP packet (header + payload). Call from network receive queue.
    func receive(packet: Data) {
        guard packet.count > kPearPacketHeaderSize else { return }

        let header = parseHeader(packet)
        guard header.version == 1, header.streamID == streamID else { return }

        // Detect sequence number gaps — each gap means at least one lost packet,
        // which likely means a frame will be delivered incomplete (corrupt artifacts).
        let seq = header.sequenceNumber
        if let expected = expectedSequenceNumber, seq != expected {
            let gap = Int(seq &- expected)
            tapLog("[DEPKT] Seq gap: expected \(expected) got \(seq) (gap=\(gap)) — frame may be corrupt")
        }
        expectedSequenceNumber = seq &+ 1

        let payload = packet[kPearPacketHeaderSize...]
        let ts = header.timestamp

        // Accumulate fragments for this timestamp
        if fragments[ts] == nil {
            fragments[ts] = Data()
            pendingTimestamps.append(ts)
            pendingTimestamps.sort()
        }
        fragments[ts]!.append(payload)
        if header.isKeyframe { frameIsKeyframe[ts] = true }

        if header.isLastPacket {
            // Complete frame — deliver it now
            deliverFrame(at: ts)
        } else if pendingTimestamps.count > jitterBufferDepth {
            // Buffer full — deliver the OLDEST pending frame (not the one that triggered
            // the overflow). Delivering newest would skip older incomplete frames entirely.
            deliverFrame(at: pendingTimestamps[0])
        }
    }

    private func deliverFrame(at timestamp: UInt32) {
        guard let nalData = fragments[timestamp] else { return }
        let isKeyframe = frameIsKeyframe[timestamp] ?? false

        fragments.removeValue(forKey: timestamp)
        frameIsKeyframe.removeValue(forKey: timestamp)
        pendingTimestamps.removeAll { $0 == timestamp }

        let frame = ReassembledFrame(nalUnit: nalData, isKeyframe: isKeyframe, timestamp: timestamp)
        onFrame?(frame)

        lastDeliveredTimestamp = timestamp
    }

    // MARK: - Header parser

    private func parseHeader(_ data: Data) -> PearPacketHeader {
        PearPacketHeader(
            version:        data[0],
            streamID:       data[1],
            sequenceNumber: UInt16(data[2]) << 8 | UInt16(data[3]),
            timestamp:      UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7]),
            flags:          data[8]
        )
    }
}
