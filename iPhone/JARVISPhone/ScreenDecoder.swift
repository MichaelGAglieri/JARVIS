import CoreMedia
import UIKit
import VideoToolbox

/// Decodes the Mac screen's H.264 video with the phone's video chip.
/// It works on its own queue, in order: each frame depends on the previous one.
final class ScreenDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jarvis.screen.decode", qos: .userInteractive)
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)

    /// `done` arrives on the main queue, with nil if the frame could not be shown.
    func decode(_ packet: VideoPacket, done: @escaping (UIImage?) -> Void) {
        queue.async { [self] in
            let image = decodeNow(packet)
            DispatchQueue.main.async { done(image) }
        }
    }

    /// A new view starts again from a keyframe.
    func reset() {
        queue.async { [self] in
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            format = nil
            parameterSets = []
        }
    }

    private func decodeNow(_ packet: VideoPacket) -> UIImage? {
        if packet.keyframe, !packet.parameterSets.isEmpty, packet.parameterSets != parameterSets {
            guard makeSession(packet.parameterSets) else { return nil }
        }
        guard let session, let format else { return nil }
        var block: CMBlockBuffer?
        let length = packet.data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = packet.data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        var image: CGImage?
        // Without asynchronous decoding the answer arrives before the function returns.
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        }
        guard let image else { return nil }
        return UIImage(cgImage: p3.flatMap { image.copy(colorSpace: $0) } ?? image)
    }

    private func makeSession(_ sets: [Data]) -> Bool {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        var description: CMFormatDescription?
        let status = withPointers(sets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return false }
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &created) == noErr, let created else { return false }
        session = created
        format = description
        parameterSets = sets
        return true
    }

    private func withPointers<T>(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> T) -> T {
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
    }
}
