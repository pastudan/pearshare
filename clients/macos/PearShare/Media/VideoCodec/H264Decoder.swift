import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - Delegate

protocol H264DecoderDelegate: AnyObject {
    func h264Decoder(_ decoder: H264Decoder, didDecodeFrame pixelBuffer: CVPixelBuffer, presentationTimestamp: CMTime)
}

// MARK: - H264Decoder

/// Wraps VideoToolbox VTDecompressionSession to decode H.264 Annex B NAL units into CVPixelBuffers.
final class H264Decoder {

    weak var delegate: H264DecoderDelegate?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    // SPS/PPS are extracted from the first keyframe and used to build the format description
    private var sps: Data?
    private var pps: Data?

    // MARK: - Feed NAL unit

    /// Feed a complete Annex B NAL unit (may contain SPS, PPS, IDR, non-IDR slices).
    func decode(annexBData: Data, isKeyframe: Bool) {
        let nalUnits = splitAnnexB(annexBData)

        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = nal[0] & 0x1F

            switch nalType {
            case 7: // SPS
                sps = nal
            case 8: // PPS
                pps = nal
                // Once we have both SPS and PPS, build the format description
                if let sps, let pps {
                    rebuildFormatDescription(sps: sps, pps: pps)
                }
            case 5: // IDR (keyframe)
                if formatDescription != nil {
                    decodeSlice(nal, isKeyframe: true)
                }
            case 1: // Non-IDR slice
                if formatDescription != nil {
                    decodeSlice(nal, isKeyframe: false)
                }
            default:
                break
            }
        }
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
        sps = nil
        pps = nil
    }

    // MARK: - Format description

    private func rebuildFormatDescription(sps: Data, pps: Data) {
        // Invalidate old session if params changed
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)

        var desc: CMVideoFormatDescription?
        let status = spsBytes.withUnsafeBytes { spsPtr in
            ppsBytes.withUnsafeBytes { ppsPtr in
                let paramSets: [UnsafePointer<UInt8>?] = [
                    spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                ]
                let paramSizes: [Int] = [spsBytes.count, ppsBytes.count]
                return paramSets.withUnsafeBufferPointer { paramSetsPtr in
                    paramSizes.withUnsafeBufferPointer { paramSizesPtr in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: nil,
                            parameterSetCount: 2,
                            parameterSetPointers: paramSetsPtr.baseAddress!,
                            parameterSetSizes: paramSizesPtr.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                    }
                }
            }
        }

        guard status == noErr, let desc else {
            print("[H264Decoder] Failed to create format description: \(status)")
            return
        }
        formatDescription = desc
        setupDecompressionSession(formatDescription: desc)
    }

    private func setupDecompressionSession(formatDescription: CMVideoFormatDescription) {
        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            print("[H264Decoder] Failed to create decompression session: \(status)")
            return
        }
        self.session = session
    }

    // MARK: - Decode slice

    private func decodeSlice(_ nalUnit: Data, isKeyframe: Bool) {
        guard let session, let formatDescription else { return }

        // Wrap NAL unit in CMBlockBuffer with AVCC 4-byte length prefix
        let nalBytes = [UInt8](nalUnit)
        let nalLength = nalBytes.count
        var avcc = Data(count: 4 + nalLength)
        avcc[0] = UInt8((nalLength >> 24) & 0xFF)
        avcc[1] = UInt8((nalLength >> 16) & 0xFF)
        avcc[2] = UInt8((nalLength >>  8) & 0xFF)
        avcc[3] = UInt8( nalLength        & 0xFF)
        avcc.replaceSubrange(4..., with: nalBytes)

        var blockBuffer: CMBlockBuffer?
        var status = avcc.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: ptr.baseAddress,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        let pts = CMTime(value: CMTimeValue(mach_absolute_time()), timescale: 1_000_000_000)

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

        // Mark as sync frame if keyframe
        if isKeyframe {
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
            guard let self, status == noErr, let pixelBuffer else { return }
            self.delegate?.h264Decoder(self, didDecodeFrame: pixelBuffer, presentationTimestamp: pts)
        }
    }

    // MARK: - Annex B splitter

    /// Splits Annex B stream (with 0x00 0x00 0x00 0x01 start codes) into individual NAL units.
    private func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var searchRange = data.startIndex ..< data.endIndex
        var lastStart: Data.Index? = nil

        while let range = data.range(of: startCode, in: searchRange) {
            if let start = lastStart {
                let nalData = data[start ..< range.lowerBound]
                if !nalData.isEmpty {
                    nals.append(Data(nalData))
                }
            }
            lastStart = range.upperBound
            searchRange = range.upperBound ..< data.endIndex
        }

        // Append final NAL unit
        if let start = lastStart, start < data.endIndex {
            nals.append(Data(data[start...]))
        }

        return nals
    }
}
