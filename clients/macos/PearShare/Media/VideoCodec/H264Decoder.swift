import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "VideoDecoder")

// MARK: - Delegate

protocol VideoDecoderDelegate: AnyObject {
    func videoDecoder(_ decoder: VideoDecoder, didDecodeFrame pixelBuffer: CVPixelBuffer, presentationTimestamp: CMTime)
}

// MARK: - VideoDecoder

/// Wraps VideoToolbox VTDecompressionSession to decode HEVC (H.265) Annex B NAL units
/// into CVPixelBuffers for Metal rendering.
///
/// HEVC NAL parsing differences from H.264:
///   - 2-byte NAL unit header; type = (nal[0] >> 1) & 0x3F
///   - Three parameter set types: VPS (32), SPS (33), PPS (34)
///   - IDR frame types: IDR_W_RADL (19), IDR_N_LP (20), CRA_NUT (21)
///   - Non-IDR inter frames: types 0–17
final class VideoDecoder {

    weak var delegate: VideoDecoderDelegate?

    /// Called (off main thread) when a VT decode error occurs. Wire this to send a
    /// keyframe request so the host re-transmits a clean starting point.
    var onDecodeError: (() -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    // HEVC parameter sets — accumulated until all three arrive, then format desc is built
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?

    // MARK: - Feed NAL unit

    func decode(annexBData: Data, isKeyframe: Bool) {
        let nalUnits = splitAnnexB(annexBData)

        for nal in nalUnits {
            guard nal.count >= 2 else { continue }

            // HEVC 2-byte NAL header: bits 14–9 of the 16-bit word are the NAL unit type
            let nalType = (nal[0] >> 1) & 0x3F

            switch nalType {
            case 32:                            // VPS
                vps = nal
            case 33:                            // SPS
                sps = nal
            case 34:                            // PPS — rebuild once we have all three
                pps = nal
                if let vps, let sps, let pps {
                    rebuildFormatDescription(vps: vps, sps: sps, pps: pps)
                }
            case 19, 20, 21:                    // IDR_W_RADL, IDR_N_LP, CRA_NUT
                if formatDescription != nil { decodeSlice(nal, isKeyframe: true) }
                else { logger.warning("VideoDecoder: dropping IDR — no format description yet") }
            default:
                // Inter frames (TRAIL_R=1, TRAIL_N=0, etc.) have types 0–17
                if nalType < 16, formatDescription != nil {
                    decodeSlice(nal, isKeyframe: false)
                }
            }
        }
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
        vps = nil; sps = nil; pps = nil
    }

    // MARK: - Format description

    private func rebuildFormatDescription(vps: Data, sps: Data, pps: Data) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil

        let vpsBytes = [UInt8](vps)
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)

        var desc: CMVideoFormatDescription?

        let status = vpsBytes.withUnsafeBytes { vpsPtr in
            spsBytes.withUnsafeBytes { spsPtr in
                ppsBytes.withUnsafeBytes { ppsPtr in
                    let paramSets: [UnsafePointer<UInt8>] = [
                        vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let paramSizes: [Int] = [vpsBytes.count, spsBytes.count, ppsBytes.count]
                    return paramSets.withUnsafeBufferPointer { setsPtr in
                        paramSizes.withUnsafeBufferPointer { sizesPtr in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: nil,
                                parameterSetCount: 3,
                                parameterSetPointers: setsPtr.baseAddress!,
                                parameterSetSizes: sizesPtr.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &desc
                            )
                        }
                    }
                }
            }
        }

        guard status == noErr, let desc else {
            logger.error("VideoDecoder: HEVC format description creation failed (status \(status))")
            return
        }

        logger.info("VideoDecoder: HEVC format description ready")
        formatDescription = desc
        setupDecompressionSession(formatDescription: desc)
    }

    private func setupDecompressionSession(formatDescription: CMVideoFormatDescription) {
        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        // Explicitly request the hardware HEVC decoder. Without this hint VideoToolbox may
        // fall back to a software decoder on some configurations, which is 3–5× slower to
        // initialise and decode — directly impacting first-frame latency.
        let spec: [NSString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            logger.error("VideoDecoder: decompression session creation failed (status \(status))")
            return
        }

        logger.info("VideoDecoder: decompression session ready")
        self.session = session
    }

    // MARK: - Decode slice

    private func decodeSlice(_ nalUnit: Data, isKeyframe: Bool) {
        guard let session, let formatDescription else { return }

        let nalBytes = [UInt8](nalUnit)
        let nalLength = nalBytes.count
        var avcc = Data(count: 4 + nalLength)
        avcc[0] = UInt8((nalLength >> 24) & 0xFF)
        avcc[1] = UInt8((nalLength >> 16) & 0xFF)
        avcc[2] = UInt8((nalLength >>  8) & 0xFF)
        avcc[3] = UInt8( nalLength        & 0xFF)
        avcc.replaceSubrange(4..., with: nalBytes)

        var blockBuffer: CMBlockBuffer?
        let avccCount = avcc.count
        var status = avcc.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: ptr.baseAddress,
                blockLength: avccCount,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        if isKeyframe {
            // Flush all pending async callbacks from the previous GOP before starting the
            // new keyframe. Without this, out-of-order or corrupted P-frames from the old
            // GOP fire their callbacks after the IDR lands, producing green artifacts.
            VTDecompressionSessionWaitForAsynchronousFrames(session)

            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
            if let array = attachments as? [NSMutableDictionary], let first = array.first {
                first[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
        }

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, pixelBuffer, pts, _ in
            guard let self, status == noErr, let pixelBuffer else {
                if status != noErr {
                    logger.error("VideoDecoder: decode error \(status)")
                    self?.onDecodeError?()
                }
                return
            }
            self.delegate?.videoDecoder(self, didDecodeFrame: pixelBuffer, presentationTimestamp: pts)
        }
    }

    // MARK: - Annex B splitter (identical to H.264 — start codes are the same)

    private func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var searchRange = data.startIndex ..< data.endIndex
        var lastStart: Data.Index? = nil

        while let range = data.range(of: startCode, in: searchRange) {
            if let start = lastStart {
                let nalData = data[start ..< range.lowerBound]
                if !nalData.isEmpty { nals.append(Data(nalData)) }
            }
            lastStart = range.upperBound
            searchRange = range.upperBound ..< data.endIndex
        }

        if let start = lastStart, start < data.endIndex {
            nals.append(Data(data[start...]))
        }
        return nals
    }
}
