import AppKit
import AVFoundation
import ScreenCaptureKit

/// JARVIS's vision: screenshots (frontmost window or full screen) and photos
/// from the camera. Images go to the local model (or to Claude) inside the
/// conversation; they are not saved to disk.
enum VisionActions {
    /// Maximum long side: enough to read text, without too many tokens.
    static let maxSide: CGFloat = 1600

    enum VisionError: LocalizedError {
        case screenPermission, cameraPermission, noCamera, captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .screenPermission:
                return "Manca il permesso di registrazione dello schermo: Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio › JARVIS."
            case .cameraPermission:
                return "Manca il permesso della fotocamera: Impostazioni di Sistema › Privacy e sicurezza › Fotocamera › JARVIS."
            case .noCamera: return "Nessuna fotocamera disponibile."
            case .captureFailed(let m): return "Acquisizione non riuscita: \(m)"
            }
        }
    }

    // MARK: Screen

    /// `window`: the frontmost window (of another app); `screen`: the whole screen.
    /// JARVIS's windows never appear in the screenshot.
    static func captureScreen(scope: String) async throws -> (jpeg: Data, label: String) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw VisionError.screenPermission
        }
        let config = SCStreamConfiguration()
        config.showsCursor = false

        let filter: SCContentFilter
        let label: String
        if scope != "screen", let window = frontWindow(in: content) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            fit(config, width: window.frame.width, height: window.frame.height)
            label = "finestra di \(window.owningApplication?.applicationName ?? "un'app")"
        } else {
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw VisionError.captureFailed("nessuno schermo")
            }
            let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            fit(config, width: CGFloat(display.width), height: CGFloat(display.height))
            label = "schermo intero"
        }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (try jpeg(image), label)
        } catch {
            throw VisionError.captureFailed(error.localizedDescription)
        }
    }

    /// An app's largest window, for app control: also returns
    /// its position on screen, to translate a point of the image into a click.
    /// The app's main window plus its small windows above it (confirmations, alerts): before, only
    /// the main one was seen, and a Bambu Studio "Sei sicuro?" stayed invisible to the model.
    /// `frame` is the captured rectangle; `windowFrame` that of the main window, to tell whether it moved.
    static func captureWindow(pid: pid_t) async throws -> (jpeg: Data, frame: CGRect, width: Int, height: Int, window: CGWindowID, windowFrame: CGRect) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw VisionError.screenPermission
        }
        let own = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer >= 0 && $0.windowLayer < 25 }
        guard let window = own.filter({ $0.windowLayer == 0 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw VisionError.captureFailed("l'app non ha finestre visibili")
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw VisionError.captureFailed("nessuno schermo")
        }
        // The app's small windows on the same screen, even if they stick out a bit from the main one.
        let extras = own.filter { $0.windowID != window.windowID && $0.frame.width > 40 && $0.frame.height > 30 && display.frame.intersects($0.frame) }
        let area = extras.reduce(window.frame) { $0.union($1.frame) }.intersection(display.frame)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        fit(config, width: area.width, height: area.height)
        do {
            // Only the app's windows: those of other apps do not enter the photo.
            let filter = SCContentFilter(display: display, including: [window] + extras)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (try jpeg(image), area, config.width, config.height, window.windowID, window.frame)
        } catch {
            throw VisionError.captureFailed(error.localizedDescription)
        }
    }

    /// The largest frontmost window of the active app (or, if the active app is
    /// JARVIS itself, of the app below it).
    private static func frontWindow(in content: SCShareableContent) -> SCWindow? {
        let me = Bundle.main.bundleIdentifier
        let candidates = content.windows.filter {
            $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 200 && $0.frame.height > 150
                && $0.owningApplication?.bundleIdentifier != me
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != me,
           let window = candidates.filter({ $0.owningApplication?.processID == front.processIdentifier })
               .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return window
        }
        // ScreenCaptureKit lists windows from the top: the first is the front one.
        return candidates.first
    }

    private static func fit(_ config: SCStreamConfiguration, width: CGFloat, height: CGFloat) {
        // Real pixels (Retina), then reduced to the maximum long side.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var w = width * scale, h = height * scale
        let factor = min(1, maxSide / max(w, h))
        w *= factor
        h *= factor
        config.width = Int(w)
        config.height = Int(h)
    }

    // MARK: Camera

    @MainActor private static var camera: CameraSnapshot?

    /// `iphone`: the iPhone with Continuity Camera; `mac`: the Mac's camera;
    /// `auto`: the iPhone if available (frames better and focuses up close), otherwise the Mac.
    static func camera(_ choice: String) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified).devices
        let iphone = devices.first { $0.deviceType == .continuityCamera }
        let mac = devices.first { $0.deviceType == .builtInWideAngleCamera }
        switch choice {
        case "iphone": return iphone
        case "mac": return mac ?? AVCaptureDevice.default(for: .video)
        default: return iphone ?? AVCaptureDevice.systemPreferredCamera ?? mac ?? AVCaptureDevice.default(for: .video)
        }
    }

    @MainActor
    static func capturePhoto(camera choice: String = "auto") async throws -> (jpeg: Data, label: String) {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw VisionError.cameraPermission }
        guard let device = camera(choice) else {
            throw choice == "iphone"
                ? VisionError.captureFailed("iPhone non disponibile come fotocamera: tienilo vicino al Mac, bloccato e fermo, con Continuity Camera attiva (Impostazioni › Generali › AirPlay e Continuità).")
                : VisionError.noCamera
        }
        let snapshot = CameraSnapshot(device: device)
        camera = snapshot
        defer { camera = nil }
        let raw = try await snapshot.take()
        guard let image = NSImage(data: raw)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VisionError.captureFailed("foto non leggibile")
        }
        return (try jpeg(image), device.deviceType == .continuityCamera ? "iPhone" : device.localizedName)
    }

    // MARK: Utilities

    private static func jpeg(_ image: CGImage) throws -> Data {
        var cg = image
        let longest = CGFloat(max(image.width, image.height))
        if longest > maxSide {
            let factor = maxSide / longest
            let w = Int(CGFloat(image.width) * factor), h = Int(CGFloat(image.height) * factor)
            if let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = context.makeImage() { cg = scaled }
            }
        }
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw VisionError.captureFailed("conversione JPEG")
        }
        return data
    }
}

/// A single photo from the chosen camera (Mac or iPhone with Continuity Camera).
final class CameraSnapshot: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let device: AVCaptureDevice
    private var continuation: CheckedContinuation<Data, Error>?

    init(device: AVCaptureDevice) {
        self.device = device
    }

    func take() async throws -> Data {
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw VisionActions.VisionError.captureFailed("fotocamera occupata")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        defer { session.stopRunning() }
        // A moment for exposure and focus to settle.
        try? await Task.sleep(for: .milliseconds(1200))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: VisionActions.VisionError.captureFailed("nessun dato"))
        }
        continuation = nil
    }
}
