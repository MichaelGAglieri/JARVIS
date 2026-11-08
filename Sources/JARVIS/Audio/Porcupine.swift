import Foundation

/// Detector of the word "Jarvis" based on Picovoice Porcupine v4.
/// The C library is loaded at runtime with dlopen: so the project does not
/// need headers or extra linking steps.
final class Porcupine {
    private typealias InitFn = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32,
        UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<Float>?, UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32
    private typealias ProcessFn = @convention(c) (OpaquePointer?, UnsafePointer<Int16>?, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias DeleteFn = @convention(c) (OpaquePointer?) -> Void
    private typealias FrameLengthFn = @convention(c) () -> Int32
    private typealias StatusFn = @convention(c) (Int32) -> UnsafePointer<CChar>?

    let frameLength: Int
    private let handle: UnsafeMutableRawPointer
    private var object: OpaquePointer?
    private let process: ProcessFn
    private let delete: DeleteFn
    private var pending: [Int16] = []

    init(accessKey: String, sensitivity: Float) throws {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("porcupine") else {
            throw JarvisError.wakeWord("risorse mancanti")
        }
        let lib = dir.appendingPathComponent("libpv_porcupine.dylib").path
        let model = dir.appendingPathComponent("porcupine_params.pv").path
        let keyword = dir.appendingPathComponent("jarvis_mac.ppn").path

        guard let handle = dlopen(lib, RTLD_NOW) else {
            throw JarvisError.wakeWord("impossibile caricare la libreria")
        }
        self.handle = handle
        func symbol<T>(_ name: String, as: T.Type) throws -> T {
            guard let sym = dlsym(handle, name) else { throw JarvisError.wakeWord("simbolo \(name) mancante") }
            return unsafeBitCast(sym, to: T.self)
        }
        let initFn = try symbol("pv_porcupine_init", as: InitFn.self)
        process = try symbol("pv_porcupine_process", as: ProcessFn.self)
        delete = try symbol("pv_porcupine_delete", as: DeleteFn.self)
        frameLength = Int(try symbol("pv_porcupine_frame_length", as: FrameLengthFn.self)())
        let statusString = try symbol("pv_status_to_string", as: StatusFn.self)

        var obj: OpaquePointer?
        var sens = sensitivity
        // "cpu:1" = a single thread: enough for the wake word, and it uses very little.
        let status = accessKey.withCString { key in
            model.withCString { modelPath in
                "cpu:1".withCString { device in
                    keyword.withCString { kw in
                        var paths: [UnsafePointer<CChar>?] = [kw]
                        return initFn(key, modelPath, device, 1, &paths, &sens, &obj)
                    }
                }
            }
        }
        guard status == 0, let obj else {
            let message = statusString(status).map { String(cString: $0) } ?? "errore \(status)"
            dlclose(handle)
            throw JarvisError.wakeWord(message)
        }
        object = obj
    }

    deinit {
        delete(object)
        dlclose(handle)
    }

    /// Takes Float samples at 16 kHz and returns true if the word "Jarvis"
    /// was recognised in this block.
    func feed(_ samples: [Float]) -> Bool {
        pending.reserveCapacity(pending.count + samples.count)
        for s in samples {
            pending.append(Int16(max(-1, min(1, s)) * 32767))
        }
        var detected = false
        var index: Int32 = -1
        var offset = 0
        while pending.count - offset >= frameLength {
            pending.withUnsafeBufferPointer { buf in
                _ = process(object, buf.baseAddress! + offset, &index)
            }
            if index >= 0 { detected = true }
            offset += frameLength
        }
        pending.removeFirst(offset)
        return detected
    }
}
