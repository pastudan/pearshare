import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - Delegate

protocol VideoEncoderDelegate: AnyObject {
    /// Called for each encoded NAL unit (Annex B format, starts with 0x00 0x00 0x00 0x01).
    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnit data: Data, isKeyframe: Bool, presentationTimestamp: CMTime)
}

// MARK: - VideoEncoder

/// Wraps VideoToolbox VTCompressionSession to encode CVPixelBuffers into HEVC (H.265) NAL units.
/// Uses hardware acceleration on all Apple Silicon Macs.
///
/// Tuned for productivity screen sharing:
///   - 15 fps — enough for document/IDE work; means more bits available per frame
///   - 8 Mbps HEVC ≈ 16+ Mbps H.264 in perceived quality
///   - Real-time mode kept on so encoding latency stays low for interactive remote control
final class VideoEncoder {

    weak var delegate: VideoEncoderDelegate?

    var targetBitrate: Int = 8_000_000  // 8 Mbps; HEVC is ~2× more efficient than H.264
    var frameRate: Double = 15          // fps; optimal for productivity screen sharing

    private var session: VTCompressionSession?
    private var frameCount: Int64 = 0

    // MARK: - Setup

    func prepare(width: Int, height: Int) throws {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw VideoCodecError.sessionCreationFailed(status)
        }
        self.session = session
        try configureSession(session)
        try VTCompressionSessionPrepareToEncodeFrames(session).throwIfNotNoErr()
    }

    private func configureSession(_ session: VTCompressionSession) throws {
        // Real-time keeps encoding latency low — important for interactive remote control
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                                 value: kCFBooleanTrue).throwIfNotNoErr()

        // No B-frames: forward-only to avoid decoder reordering latency
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                                 value: kCFBooleanFalse).throwIfNotNoErr()

        // HEVC Main profile — 8-bit, hardware-accelerated on all Apple Silicon
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main_AutoLevel).throwIfNotNoErr()

        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: targetBitrate as CFNumber).throwIfNotNoErr()

        // Longer GOP at low FPS: keyframe every 4 seconds improves inter-frame compression
        let keyframeInterval = Int(frameRate * 4) as CFNumber
        try VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: keyframeInterval).throwIfNotNoErr()

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

        // Force keyframe every 4 seconds as a belt-and-suspenders guarantee
        var frameProperties: CFDictionary? = nil
        if frameCount % Int64(frameRate * 4) == 1 {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.handleEncodedSample(sampleBuffer)
        }
    }

    func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    // MARK: - Output processing

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let isKeyframe: Bool
        if let array = attachmentsArray as? [[CFString: Any]], let first = array.first {
            isKeyframe = (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        } else {
            isKeyframe = true
        }

        let byteCount = dataBuffer.dataLength
        var avccData = Data(count: byteCount)
        let copyStatus = avccData.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let dest = ptr.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: byteCount, destination: dest)
        }
        guard copyStatus == noErr else { return }

        var annexB = Data()

        // On keyframes, prepend VPS + SPS + PPS so the decoder can always initialise
        if isKeyframe, let fmt = sampleBuffer.formatDescription {
            annexB.append(Self.extractParameterSets(from: fmt))
        }

        annexB.append(Self.avccToAnnexB(avccData))
        guard !annexB.isEmpty else { return }

        delegate?.videoEncoder(self, didEncodeNALUnit: annexB, isKeyframe: isKeyframe, presentationTimestamp: pts)
    }

    // MARK: - Extract VPS/SPS/PPS from HEVC format description

    private static func extractParameterSets(from fmt: CMVideoFormatDescription) -> Data {
        var result = Data()
        var count = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)

        for i in 0 ..< count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fmt, parameterSetIndex: i,
                parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil)
            if status == noErr, let ptr, size > 0 {
                result.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                result.append(UnsafeBufferPointer(start: ptr, count: size))
            }
        }
        return result
    }

    // MARK: - AVCC → Annex B (identical framing to H.264)

    static func avccToAnnexB(_ avcc: Data) -> Data {
        var result = Data()
        result.reserveCapacity(avcc.count + 16)
        var offset = 0

        avcc.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!
            while offset + 4 <= ptr.count {
                let nalLength = Int(UInt32(bigEndian: (base + offset).loadUnaligned(as: UInt32.self)))
                offset += 4
                guard nalLength > 0, offset + nalLength <= ptr.count else { break }
                result.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                result.append(avcc[offset ..< offset + nalLength])
                offset += nalLength
            }
        }
        return result
    }
}

// MARK: - Error

enum VideoCodecError: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case encodingFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let s): return "VTCompressionSession creation failed: \(s)"
        case .encodingFailed(let s):        return "Video codec error: \(s)"
        }
    }
}

// MARK: - OSStatus helper

extension OSStatus {
    func throwIfNotNoErr() throws {
        guard self == noErr else { throw VideoCodecError.encodingFailed(self) }
    }
}
