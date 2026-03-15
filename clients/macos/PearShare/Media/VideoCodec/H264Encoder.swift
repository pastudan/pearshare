import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - Delegate

protocol H264EncoderDelegate: AnyObject {
    /// Called for each encoded NAL unit (Annex B format, starts with 0x00 0x00 0x00 0x01).
    func h264Encoder(_ encoder: H264Encoder, didEncodeNALUnit data: Data, isKeyframe: Bool, presentationTimestamp: CMTime)
}

// MARK: - H264Encoder

/// Wraps VideoToolbox VTCompressionSession to encode CVPixelBuffers into H.264 NAL units.
/// Uses hardware acceleration when available (always on Apple Silicon, usually on Intel).
final class H264Encoder {

    weak var delegate: H264EncoderDelegate?

    var targetBitrate: Int = 4_000_000  // bps, adjustable
    var frameRate: Double = 30

    private var session: VTCompressionSession?
    private var frameCount: Int64 = 0

    // MARK: - Setup

    func prepare(width: Int, height: Int) throws {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,       // we use the async block API below
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw H264Error.sessionCreationFailed(status)
        }
        self.session = session

        try configureSession(session)
        try VTCompressionSessionPrepareToEncodeFrames(session).throwIfNotNoErr()
    }

    private func configureSession(_ session: VTCompressionSession) throws {
        // Real-time encoding — no buffering, no lookahead
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue).throwIfNotNoErr()

        // No B-frames — forward-only for minimum latency
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse).throwIfNotNoErr()

        // High profile for best quality/compression, auto level
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_High_AutoLevel).throwIfNotNoErr()

        // Bitrate
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: targetBitrate as CFNumber).throwIfNotNoErr()

        // Keyframe every 2 seconds
        let keyframeInterval = Int(frameRate * 2) as CFNumber
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: keyframeInterval).throwIfNotNoErr()

        // H.264 Annex B output (start codes) — easier to packetize than AVCC
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression,
                                 value: kCFBooleanTrue).throwIfNotNoErr()
    }

    // MARK: - Encode

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        frameCount += 1

        // Force keyframe every 2s (backup in case VTSession doesn't)
        var frameProperties: CFDictionary? = nil
        if frameCount % Int64(frameRate * 2) == 1 {
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue
            ] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.handleEncodedSample(sampleBuffer, flags: flags)
        }
    }

    func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    // MARK: - Output processing

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // A frame is a keyframe if it is NOT marked as non-sync
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let isKeyframe: Bool
        if let array = attachmentsArray as? [[CFString: Any]], let first = array.first {
            isKeyframe = (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        } else {
            isKeyframe = true
        }

        var data = Data()
        CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: dataBuffer.dataLength, destination: &data)

        let annexB = Self.avccToAnnexB(data)
        delegate?.h264Encoder(self, didEncodeNALUnit: annexB, isKeyframe: isKeyframe, presentationTimestamp: pts)
    }

    // MARK: - AVCC → Annex B conversion

    /// VideoToolbox produces AVCC-style NAL units (4-byte big-endian length prefix).
    /// We convert to Annex B (0x00 0x00 0x00 0x01 start code) for easier framing.
    static func avccToAnnexB(_ avcc: Data) -> Data {
        var result = Data()
        result.reserveCapacity(avcc.count + 16)
        var offset = 0

        while offset < avcc.count - 4 {
            // Read 4-byte big-endian NAL unit length
            let nalLength = avcc.withUnsafeBytes { ptr -> Int in
                let raw = ptr.baseAddress!.advanced(by: offset)
                return Int(UInt32(bigEndian: raw.load(as: UInt32.self)))
            }
            offset += 4
            guard nalLength > 0, offset + nalLength <= avcc.count else { break }

            // Annex B start code
            result.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            result.append(avcc[offset ..< offset + nalLength])
            offset += nalLength
        }

        return result
    }
}

// MARK: - Error

enum H264Error: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case encodingFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let s): return "VTCompressionSession creation failed: \(s)"
        case .encodingFailed(let s):        return "H.264 encoding failed: \(s)"
        }
    }
}

// MARK: - OSStatus helper

extension OSStatus {
    func throwIfNotNoErr() throws {
        guard self == noErr else { throw H264Error.encodingFailed(self) }
    }
}
