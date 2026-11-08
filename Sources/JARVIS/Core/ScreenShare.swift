import AppKit
import CoreMedia
import VideoToolbox
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// What goes to the phone: a photo (older apps) or a piece of video.
enum ScreenFrame {
    case photo(Data)
    case video(VideoPacket)
}

/// Sends the Mac screen to the phone only while the view is open. A continuous stream
/// (ScreenCaptureKit) always keeps the latest image ready. New apps receive H.264 video
/// at the Mac's resolution, compressed by the video chip; older ones one JPEG photo at a time.
/// Only a few images leave without the phone's acknowledgment, so on 4G it slows down by itself;
/// with the screen still nothing is sent.
@MainActor
final class ScreenShare {
    /// Photos for older apps: an image stays around 60-120 KB.
    private static let photoWidth = 1280
    nonisolated private static let photoQuality = 0.45
    /// Full-resolution video: 2560 points on a MacBook screen.
    private static let videoMaxWidth = 3840

    private var task: Task<Void, Never>?
    private var stream: SCStream?
    private var output: FrameOutput?
    private var inFlight = 0
    private var lastAck = Date()
    private var sentAt: [Date] = []
    /// Average time between send and acknowledgment: on a slow link the video drops quality, not smoothness.
    private var roundTrip = 0.1

    var isActive: Bool { task != nil }

    /// `failed` receives the reason if capture is not possible, and the view closes.
    func start(video: Bool, send: @escaping (ScreenFrame) -> Void, failed: @escaping (String) -> Void) {
        guard task == nil else { return }
        inFlight = 0
        sentAt = []
        roundTrip = 0.1
        lastAck = Date()
        let output = FrameOutput()
        self.output = output
        task = Task { [weak self] in
            let size: (width: Int, height: Int)
            do {
                let (stream, streamSize) = try await Self.makeStream(output: output, video: video)
                guard let self, !Task.isCancelled else { stream.stopCapture { _ in }; return }
                self.stream = stream
                size = streamSize
            } catch {
                Diagnostics.log("iphone    schermo non catturato: \(error)")
                failed("Non riesco a vedere lo schermo: serve il permesso Registrazione schermo per JARVIS, sul Mac.")
                self?.task = nil
                return
            }
            let encoder = video ? VideoEncoder(width: size.width, height: size.height) : nil
            if video, encoder == nil { Diagnostics.log("iphone    codificatore video non disponibile: mando foto") }
            var last = Date.distantPast
            var lastFresh = Date()
            var refined = true
            var sent = 0, bytes = 0, keyframes = 0
            var encodeTime = 0.0
            var bitRate = 0
            while let self, !Task.isCancelled {
                if output.stoppedError != nil {
                    Diagnostics.log("iphone    flusso dello schermo fermo: \(output.stoppedError.map { "\($0)" } ?? "")")
                    failed("La vista dello schermo si è interrotta sul Mac.")
                    self.stopStream()
                    self.task = nil
                    return
                }
                // A lost acknowledgment must not stop the view.
                if self.inFlight > 0, Date().timeIntervalSince(self.lastAck) > 3 {
                    self.inFlight = 0
                    self.sentAt = []
                }
                let cool = ProcessInfo.processInfo.thermalState == .nominal
                // Video: 30 per second and three in flight; photos: 12 and two. With the Mac hot, far fewer.
                let pause = encoder != nil ? (cool ? 1.0 / 30 : 1.0 / 8) : (cool ? 1.0 / 12 : 0.5)
                let limit = encoder != nil ? 3 : 2
                guard self.inFlight < limit, Date().timeIntervalSince(last) >= pause else {
                    try? await Task.sleep(for: .milliseconds(8))
                    continue
                }
                var frame = output.takeNew()
                if frame != nil {
                    lastFresh = Date()
                    refined = false
                } else if let encoder, !refined, Date().timeIntervalSince(lastFresh) > 0.4 {
                    // Just went still: the last image is compressed again, so the text becomes sharp again.
                    frame = output.latestFrame()
                    refined = true
                    encoder.forceKeyframe()
                }
                guard let frame else {
                    try? await Task.sleep(for: .milliseconds(8))
                    continue
                }
                last = Date()
                let began = Date()
                let item: ScreenFrame?
                if let encoder {
                    // Slow link (4G): fewer bits, same smoothness.
                    let wanted = self.roundTrip > 0.3 ? 2_500_000 : self.roundTrip > 0.15 ? 5_000_000 : 10_000_000
                    if wanted != bitRate {
                        bitRate = wanted
                        encoder.setBitRate(wanted)
                    }
                    item = await Task.detached(priority: .userInitiated) { encoder.encode(frame.buffer).map(ScreenFrame.video) }.value
                } else {
                    item = await Task.detached(priority: .userInitiated) { Self.jpeg(frame.buffer).map(ScreenFrame.photo) }.value
                }
                guard let item, !Task.isCancelled else { continue }
                sent += 1
                encodeTime += Date().timeIntervalSince(began)
                switch item {
                case .photo(let data): bytes += data.count
                case .video(let packet):
                    bytes += packet.data.count
                    if packet.keyframe { keyframes += 1 }
                }
                if sent == 1 || sent % 300 == 0 {
                    Diagnostics.log(String(format: "iphone    schermo %@ %dx%d: %d immagini (%d chiave), media %d KB, compressione %.1f ms, andata e ritorno %.0f ms",
                                           encoder != nil ? "video" : "foto", size.width, size.height, sent, keyframes, bytes / sent / 1024,
                                           encodeTime / Double(sent) * 1000, self.roundTrip * 1000))
                }
                self.inFlight += 1
                self.sentAt.append(Date())
                send(item)
            }
        }
    }

    func frameShown() {
        inFlight = max(0, inFlight - 1)
        lastAck = Date()
        if !sentAt.isEmpty {
            roundTrip = roundTrip * 0.8 + Date().timeIntervalSince(sentAt.removeFirst()) * 0.2
        }
    }

    /// After a click you want to see at once what happened.
    func hurry() {
        inFlight = 0
        sentAt = []
        output?.markNew()
    }

    func stop() {
        task?.cancel()
        task = nil
        stopStream()
    }

    private func stopStream() {
        stream?.stopCapture { _ in }
        stream = nil
        output = nil
    }

    private static func makeStream(output: FrameOutput, video: Bool) async throws -> (SCStream, (width: Int, height: Int)) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
        let configuration = SCStreamConfiguration()
        let width = min(video ? videoMaxWidth : photoWidth, display.width * 2) / 2 * 2
        configuration.width = width
        configuration.height = width * display.height / max(display.width, 1) / 2 * 2
        configuration.showsCursor = true
        // The Mac's colours are Display P3: without saying so the iPad showed them dull.
        configuration.colorSpaceName = CGColorSpace.displayP3
        if video {
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        } else {
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        }
        configuration.queueDepth = 4
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        return (stream, (configuration.width, configuration.height))
    }

    nonisolated private static func jpeg(_ buffer: CVPixelBuffer) -> Data? {
        var captured: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &captured)
        guard let raw = captured, let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let image = raw.copy(colorSpace: p3) ?? raw
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: photoQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// H.264 from the Mac's video chip: no reordered frames, so each one comes out at once.
final class VideoEncoder: @unchecked Sendable {
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var index: Int64 = 0
    private var keyframeWanted = true

    init?(width: Int, height: Int) {
        var created: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr,
              let created else { return nil }
        session = created
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 300,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_P3_D65,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        setBitRate(10_000_000)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { VTCompressionSessionInvalidate(session) }

    func setBitRate(_ bitsPerSecond: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
        // At most one and a half times the average in a second: a keyframe does not clog the link.
        let limits = [bitsPerSecond / 8 * 3 / 2, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    func forceKeyframe() { lock.withLock { keyframeWanted = true } }

    /// Waits for the compressed frame: with frames in order it comes out at once.
    func encode(_ buffer: CVPixelBuffer) -> VideoPacket? {
        let (time, key) = lock.withLock { () -> (CMTime, Bool) in
            index += 1
            defer { keyframeWanted = false }
            return (CMTime(value: index, timescale: 30), keyframeWanted)
        }
        var packet: VideoPacket?
        let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
                                                     frameProperties: options, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample else { return }
            packet = Self.packet(from: sample)
        }
        guard status == noErr else { return nil }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: time)
        return packet
    }

    private static func packet(from sample: CMSampleBuffer) -> VideoPacket? {
        guard let block = sample.dataBuffer, let format = sample.formatDescription else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var sets: [Data] = []
        if keyframe {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr, length > 0 else { return nil }
        return VideoPacket(keyframe: keyframe, parameterSets: sets, data: data)
    }
}

/// Receives the images from the stream and keeps only the latest, marking whether it is new.
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame: @unchecked Sendable { let buffer: CVPixelBuffer }

    let queue = DispatchQueue(label: "jarvis.screen", qos: .userInitiated)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var fresh = false
    private var error: Error?

    var stoppedError: Error? { lock.withLock { error } }

    func takeNew() -> Frame? {
        lock.withLock {
            guard fresh, let latest else { return nil }
            fresh = false
            return Frame(buffer: latest)
        }
    }

    func latestFrame() -> Frame? { lock.withLock { latest.map(Frame.init) } }

    func markNew() { lock.withLock { if latest != nil { fresh = true } } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        lock.withLock {
            latest = buffer
            fresh = true
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { self.error = error }
    }
}

/// The Mac's mouse and keyboard driven by hand from the phone.
enum RemoteInput {
    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, count: Int64 = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: count)
        event?.post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint, count: Int) {
        // Some buttons respond only if the pointer has passed over them.
        post(.mouseMoved, at: point)
        usleep(100_000)
        for n in 1...max(count, 1) {
            post(.leftMouseDown, at: point, count: Int64(n))
            usleep(50_000)
            post(.leftMouseUp, at: point, count: Int64(n))
            if n < count { usleep(70_000) }
        }
    }

    /// Dragging: press, move while holding, release. `pressed` avoids a release without a press.
    private(set) static var pressed = false

    static func press(at point: CGPoint) {
        if pressed { release(at: point) }
        post(.mouseMoved, at: point)
        usleep(60_000)
        post(.leftMouseDown, at: point)
        pressed = true
    }

    static func drag(to point: CGPoint) {
        guard pressed else { return }
        post(.leftMouseDragged, at: point)
    }

    static func release(at point: CGPoint) {
        guard pressed else { return }
        post(.leftMouseDragged, at: point)
        usleep(20_000)
        post(.leftMouseUp, at: point)
        pressed = false
    }

    static func rightClick(at point: CGPoint) {
        post(.mouseMoved, at: point)
        usleep(100_000)
        post(.rightMouseDown, at: point, button: .right)
        usleep(50_000)
        post(.rightMouseUp, at: point, button: .right)
    }

    static func scroll(at point: CGPoint, by amount: Int) {
        post(.mouseMoved, at: point)
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(clamping: amount), wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    /// False if the key is not among the expected ones.
    static func press(_ name: String) -> Bool {
        let codes: [String: CGKeyCode] = ["return": 36, "delete": 51, "escape": 53, "tab": 48]
        guard let code = codes[name] else { return false }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
        return true
    }
}
