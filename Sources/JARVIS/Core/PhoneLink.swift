import CryptoKit
import Foundation
import Network

/// The wire between JARVIS on the Mac and the app on the iPhone: both compile the same file.
///
/// TCP on the local network, encrypted with pre-shared-key TLS: the key derives from the pairing
/// code, which has 100 random bits and never travels over the network. Without the code one does not
/// even complete the handshake, so every successful connection is already authenticated.
enum PhoneLink {
    static let serviceType = "_jarvis._tcp"
    static let port: UInt16 = 47831
    /// 2: the screen arrives as H.264 video (apps at version 1 still receive JPEG photos).
    static let version = 2
    /// A long spoken sentence stays under one megabyte: beyond 16 MB it is an error, not audio.
    static let maxFrame = 16 * 1024 * 1024

    /// 20 characters without I, L, O, U, so they are not confused when copied by hand.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func newCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<20).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return stride(from: 0, to: 20, by: 4).map { String(characters[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// The code without hyphens and with ambiguous letters corrected.
    static func normalized(_ code: String) -> String {
        var clean = ""
        for character in code.uppercased() {
            switch character {
            case "O": clean.append("0")
            case "I", "L": clean.append("1")
            default: if alphabet.contains(character) { clean.append(character) }
            }
        }
        return clean
    }

    static func isValid(_ code: String) -> Bool { normalized(code).count == 20 }

    /// Pre-shared-key TLS connection, with TCP that notices a dropped network early.
    static func parameters(code: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let tls = NWProtocolTLS.Options()
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(normalized(code).utf8)),
                                         info: Data("jarvis-iphone-1".utf8), outputByteCount: 32)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("jarvis".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Only the home network and Tailscale, the private network between the user's devices: not from the internet.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let b = [UInt8](address.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 127 || b[0] == 10 || (b[0] == 192 && b[1] == 168)
                || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 169 && b[1] == 254)
                || isTailscale(b)
        case .ipv6(let address):
            if address.isLoopback || address.isLinkLocal { return true }
            if let mapped = address.asIPv4 { return isLocal(.hostPort(host: .ipv4(mapped), port: 0)) }
            let first = address.rawValue.first ?? 0
            return first & 0xFE == 0xFC
        default:
            return false
        }
    }
}

extension PhoneLink {
    /// Tailscale assigns 100.64.0.0/10 addresses, which cannot be reached from the internet.
    static func isTailscale(_ b: [UInt8]) -> Bool {
        b.count == 4 && b[0] == 100 && (64...127).contains(b[1])
    }

    /// The phone comes through Tailscale, so it may be away from home.
    static func isOutside(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isTailscale([UInt8](address.rawValue))
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return isTailscale([UInt8](mapped.rawValue)) }
            return [UInt8](address.rawValue).starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
        default:
            return false
        }
    }
}

/// What the two sides tell each other, apart from audio.
struct PhoneMessage: Codable, Equatable {
    enum Kind: String, Codable {
        // From iPhone to Mac
        case hello, command, stop, played
        /// `number` 1 opens the screen view, 0 closes it. `frameShown`: ready for the next photo.
        case watch, frameShown
        /// Only with the view open. `pointer`: `text` is click, double, right or scroll, `x` and `y` from 0 to 1
        /// on the image, `number` the points to scroll. `typing`: text to type. `key`: return, delete, escape, tab.
        case pointer, typing, key
        // From Mac to iPhone
        case welcome, state, heard, reply, stopAudio, notice
        /// The screen view was closed on the Mac's side, with the reason in `text`.
        case watchEnded
        /// Another paired device connected: whoever receives this does not retry by itself.
        case replaced
    }

    var kind: Kind
    var text: String?
    var number: Int?
    /// In the welcome: the Mac's Tailscale address, which the phone uses when away from home.
    var address: String?
    var x: Double?
    var y: Double?

    init(_ kind: Kind, text: String? = nil, number: Int? = nil, address: String? = nil, x: Double? = nil, y: Double? = nil) {
        self.x = x
        self.y = y
        self.kind = kind
        self.text = text
        self.number = number
        self.address = address
    }
}

/// A voice: from the iPhone a sentence to transcribe at 16 kHz, from the Mac a sentence to play.
struct PhoneClip {
    var id: UInt32
    var sampleRate: UInt32
    var samples: [Float]

    var duration: Double { Double(samples.count) / Double(max(sampleRate, 1)) }

    /// 16-bit samples: half the bandwidth, and for voice the difference cannot be heard.
    func encoded() -> Data {
        var data = Data(capacity: 8 + samples.count * 2)
        withUnsafeBytes(of: id.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        let ints = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        ints.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    init(id: UInt32, sampleRate: UInt32, samples: [Float]) {
        self.id = id
        self.sampleRate = sampleRate
        self.samples = samples
    }

    init?(_ data: Data) {
        guard data.count >= 8, (data.count - 8) % 2 == 0 else { return nil }
        let bytes = [UInt8](data)
        func word(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        id = word(0)
        sampleRate = word(4)
        guard (8_000...96_000).contains(sampleRate) else { return nil }
        samples = stride(from: 8, to: bytes.count, by: 2).map { i in
            Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32767
        }
    }
}

/// A message connection over TCP: four bytes of length, one of type, the content.
/// Everything goes through the main queue, like the rest of the app.
final class PhoneChannel {
    private enum FrameKind: UInt8 { case message = 0, clip = 1, screen = 2, video = 3 }

    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((PhoneMessage) -> Void)?
    var onClip: ((PhoneClip) -> Void)?
    /// A JPEG photo of the Mac screen.
    var onScreen: ((Data) -> Void)?
    /// A piece of the H.264 video of the Mac screen.
    var onVideo: ((VideoPacket) -> Void)?
    /// Only once, with the reason if it is an error.
    var onClosed: ((NWError?) -> Void)?
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveHeader()
            case .failed(let error):
                self.finish(error)
            case .waiting(let error):
                // Wrong code or Mac off: whoever opened the wire decides whether to retry.
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func close() {
        finish(nil)
    }

    private func finish(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClosed?(error)
        // The functions retain the channel: dropping them frees it.
        onReady = nil
        onMessage = nil
        onClip = nil
        onScreen = nil
        onVideo = nil
        onClosed = nil
    }

    func send(_ message: PhoneMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        send(.message, data)
    }

    /// The last message before closing: closing right after `send` would lose it.
    func sendAndClose(_ message: PhoneMessage) {
        guard !closed, let data = try? JSONEncoder().encode(message) else { return finish(nil) }
        var frame = Data()
        withUnsafeBytes(of: UInt32(data.count + 1).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(FrameKind.message.rawValue)
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in self?.finish(nil) })
    }

    func send(_ clip: PhoneClip) {
        send(.clip, clip.encoded())
    }

    func send(screen frame: Data) {
        send(.screen, frame)
    }

    func send(video packet: VideoPacket) {
        send(.video, packet.encoded())
    }

    private func send(_ kind: FrameKind, _ payload: Data) {
        guard !closed else { return }
        var frame = Data(capacity: payload.count + 5)
        withUnsafeBytes(of: UInt32(payload.count + 1).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(kind.rawValue)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error { return self.finish(error) }
            guard let data, data.count == 4 else {
                if isComplete { self.finish(nil) } else { self.receiveHeader() }
                return
            }
            let length = data.reduce(0) { $0 << 8 | Int($1) }
            guard (1...PhoneLink.maxFrame).contains(length) else { return self.finish(nil) }
            self.receiveBody(length)
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let error { return self.finish(error) }
            guard let data, data.count == length else { return self.finish(nil) }
            self.deliver(data)
            self.receiveHeader()
        }
    }

    private func deliver(_ frame: Data) {
        let payload = frame.dropFirst()
        switch FrameKind(rawValue: frame[frame.startIndex]) {
        case .message:
            if let message = try? JSONDecoder().decode(PhoneMessage.self, from: payload) { onMessage?(message) }
        case .clip:
            if let clip = PhoneClip(Data(payload)) { onClip?(clip) }
        case .screen:
            onScreen?(Data(payload))
        case .video:
            if let packet = VideoPacket(Data(payload)) { onVideo?(packet) }
        case nil:
            break
        }
    }
}

/// An H.264 frame: units with four bytes of length in front, as VideoToolbox gives them.
/// The keyframe also carries SPS and PPS, so the phone knows how to decode.
/// Format: one byte (1 = key), one byte with the number of parameter sets, each with two bytes of
/// length, then the frame.
struct VideoPacket {
    var keyframe: Bool
    var parameterSets: [Data]
    var data: Data

    init(keyframe: Bool, parameterSets: [Data], data: Data) {
        self.keyframe = keyframe
        self.parameterSets = parameterSets
        self.data = data
    }

    init?(_ raw: Data) {
        let bytes = [UInt8](raw)
        guard bytes.count >= 2 else { return nil }
        keyframe = bytes[0] & 1 == 1
        var index = 2
        var sets: [Data] = []
        for _ in 0..<Int(bytes[1]) {
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard length > 0, index + length <= bytes.count else { return nil }
            sets.append(Data(bytes[index..<index + length]))
            index += length
        }
        guard index < bytes.count else { return nil }
        parameterSets = sets
        data = Data(bytes[index...])
    }

    func encoded() -> Data {
        var out = Data(capacity: data.count + 64)
        out.append(keyframe ? 1 : 0)
        out.append(UInt8(min(parameterSets.count, 255)))
        for set in parameterSets.prefix(255) {
            out.append(UInt8(set.count >> 8 & 0xFF))
            out.append(UInt8(set.count & 0xFF))
            out.append(set)
        }
        out.append(data)
        return out
    }
}
