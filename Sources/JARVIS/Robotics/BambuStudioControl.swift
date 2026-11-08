import AppKit
import ScreenCaptureKit
import Vision

/// Printer commands through Bambu Studio's buttons: the firmware rejects unsigned direct
/// commands, and developer mode would cut the link with the phone app.
///
/// Bambu Studio's buttons have no Accessibility names and the panel moves by itself.
/// So every click follows three rules:
/// - the button is found by reading its label on screen, right before pressing, and its
///   position must stay still between two readings;
/// - no window of another app may be above that point;
/// - the outcome is checked on what the printer reports, not on what the app shows.
@MainActor
final class BambuStudioControl {
    private static let bundleID = "com.bambulab.bambu-studio"
    /// Window regions, from 0 to 1.
    private static let tabBar = CGRect(x: 0, y: 0, width: 0.75, height: 0.09)
    private static let topRight = CGRect(x: 0.6, y: 0, width: 0.4, height: 0.09)
    /// The button of the send window: the window title also starts with "Invia".
    private static let sendArea = CGRect(x: 0.5, y: 0.75, width: 0.5, height: 0.25)
    private static let sideBar = CGRect(x: 0, y: 0.05, width: 0.16, height: 0.4)

    private let printer: BambuPrinter
    private let appControl: AppControl
    private var busy = false
    private var watcher: Task<Void, Never>?
    /// When the filament operation ends: the sentence to say, in Italian and English.
    var onFinished: ((_ id: String, _ italian: String, _ english: String) -> Void)?

    init(printer: BambuPrinter, appControl: AppControl) {
        self.printer = printer
        self.appControl = appControl
    }

    private struct Problem: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    // MARK: Filament

    /// Presses Unload or Load for the external spool, then checks that the printer starts.
    func filament(load: Bool) async -> String {
        guard !busy else { return "Sto già lavorando in Bambu Studio." }
        busy = true
        defer { busy = false }
        do {
            printer.refresh()
            try await pause(1.2)
            // An unload already halfway, for example after a JARVIS restart: resume from there.
            if !load, printer.status.manualStep == 3 {
                watchFilamentChange(load: false)
                return "Comando Scarica già in corso: la stampante aspetta che il filamento venga sfilato dal portabobina."
            }
            try await checkPrinterIsFree()
            if let present = printer.status.filamentPresent, present == load {
                return load ? "Il sensore rileva già il filamento: non c'è niente da caricare."
                            : "Il sensore non rileva filamento: non c'è niente da scaricare."
            }
            let previous = NSWorkspace.shared.frontmostApplication
            defer { if previous?.bundleIdentifier != Self.bundleID { previous?.activate() } }
            let app = try await studio()
            try await tap(["Dispositivo", "Device"], app: app, in: Self.tabBar, wait: 25)
            try await tap(["Stato", "Status"], app: app, in: Self.sideBar, wait: 8)
            try await selectExternalSpool(app: app)
            try await showFilamentButtons(app: app)
            let wanted = load ? ["Carica", "Load"] : ["Scarica", "Unload"]
            for attempt in 1...2 {
                try await tap(wanted, app: app, wait: 8) { screen in
                    // Only in the right panel: the two buttons on the same row, Unload on the left.
                    guard let unload = screen.only(["Scarica", "Unload"]), let load = screen.only(["Carica", "Load"]) else { return false }
                    return abs(unload.midY - load.midY) < 8 && unload.midX < load.midX
                }
                if await printerStartsChange(within: 15) {
                    watchFilamentChange(load: load)
                    Diagnostics.log("stampante \(load ? "carica" : "scarica") il filamento (tentativo \(attempt))")
                    return load
                        ? "Comando Carica accettato: la stampante scalda l'ugello. Il filamento va inserito a mano quando lo chiede il display."
                        : "Comando Scarica accettato: la stampante scalda l'ugello e taglia il filamento. Poi va sfilato a mano dal portabobina: lo dirò io."
                }
            }
            return "Ho premuto il pulsante ma la stampante non ha iniziato: controlla Bambu Studio."
        } catch let problem as Problem {
            return problem.text
        } catch {
            return error.localizedDescription
        }
    }

    /// The external spool must be selected before Unload. Its label is "Ext", the spool is below.
    private func selectExternalSpool(app: NSRunningApplication) async throws {
        let screen = try await settledScreen(app: app, showing: ["Ext"], wait: 8)
        guard let label = screen.only(["Ext"]) else { throw Problem("Non trovo la bobina esterna in Bambu Studio.") }
        try await click(CGPoint(x: label.midX, y: label.midY + 55), app: app)
        try await pause(1.5)
    }

    /// With a narrow window the panel goes past the edge and "Carica" is cut off: scroll right.
    private func showFilamentButtons(app: NSRunningApplication) async throws {
        for _ in 0..<4 {
            let screen = try await look(app)
            if screen.only(["Scarica", "Unload"]) != nil, screen.only(["Carica", "Load"]) != nil { return }
            let point = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 60)
            guard Self.windowOwner(at: point) == app.processIdentifier else { return }
            Self.move(to: point)
            try await pause(0.1)
            if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -160, wheel3: 0) {
                scroll.location = point
                scroll.post(tap: .cghidEventTap)
            }
            try await pause(0.5)
        }
    }

    private func checkPrinterIsFree() async throws {
        guard printer.isConfigured else { throw Problem("Stampante non configurata: mancano i dati nelle Impostazioni.") }
        printer.refresh()
        try await pause(1.2)
        guard printer.connected, printer.status.state != nil else { throw Problem("Non riesco a collegarmi alla stampante.") }
        guard !printer.status.isPrinting else { throw Problem("La stampante sta stampando: non tocco il filamento né avvio altro.") }
        guard !printer.status.isChangingFilament else { throw Problem("La stampante è già occupata: ha l'ugello in temperatura o sta cambiando filamento.") }
    }

    private func printerStartsChange(within seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if printer.status.isChangingFilament { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Follows the operation to the end. With the external spool it stops halfway: the filament must be
    /// pulled out or inserted by hand. JARVIS asks aloud and, when the sensor confirms it, presses "Finito, Continua".
    private func watchFilamentChange(load: Bool) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            let end = Date().addingTimeInterval(1200)
            var quiet = 0
            var asked: Set<Int> = []
            var pressed: Set<Int> = []
            while !Task.isCancelled, Date() < end {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let status = self.printer.status
                let stamp = Int(Date().timeIntervalSince1970)
                if let step = status.manualStep {
                    quiet = 0
                    // Only the step expected for this operation is confirmed automatically, and only
                    // when the sensor says it is done. The others are questions for the user.
                    let expected = load ? 6 : 3
                    if asked.insert(step).inserted {
                        Diagnostics.log("stampante aspetta l'utente, passaggio \(step)")
                        if step == expected, load {
                            self.onFinished?("filamento-inserisci-\(stamp)", "Signore, inserisca il filamento nella testa. Non tocchi l'ugello: è caldo.",
                                             "Sir, please insert the filament into the head. Don't touch the nozzle: it's hot.")
                        } else if step == expected {
                            self.onFinished?("filamento-sfila-\(stamp)", "Signore, sfili il filamento dal portabobina. Non tocchi l'ugello: è caldo.",
                                             "Sir, please pull the filament out from the spool holder. Don't touch the nozzle: it's hot.")
                        } else {
                            self.onFinished?("filamento-domanda-\(stamp)", "Signore, la stampante chiede qualcosa: guardi il suo schermo.",
                                             "Sir, the printer is asking something: please look at its screen.")
                        }
                    }
                    if step == expected, status.filamentPresent == load, pressed.insert(step).inserted {
                        await self.pressContinue()
                    }
                    continue
                }
                quiet = status.isChangingFilament ? 0 : quiet + 1
                guard quiet >= 3 else { continue }
                let present = status.filamentPresent
                Diagnostics.log("stampante cambio filamento finito, sensore \(present.map(String.init) ?? "?")")
                if load, present == true {
                    self.onFinished?("filamento-\(stamp)", "Filamento caricato, signore.", "Filament loaded, sir.")
                } else if !load, present == false {
                    self.onFinished?("filamento-\(stamp)", "Filamento scaricato, signore.", "Filament unloaded, sir.")
                } else {
                    self.onFinished?("filamento-\(stamp)", "L'operazione sul filamento è finita, signore, ma il sensore dice altro: controlli la stampante.",
                                     "The filament operation has ended, sir, but the sensor disagrees: please check the printer.")
                }
                return
            }
        }
    }

    /// The manual step is done: press "Finito, Continua", unless someone already did it on the printer.
    private func pressContinue() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let previous = NSWorkspace.shared.frontmostApplication
        defer { if previous?.bundleIdentifier != Self.bundleID { previous?.activate() } }
        do {
            guard let app = Self.instances().last else { throw Problem("Bambu Studio non è aperta.") }
            try await bringToFront(app)
            try await tap(["Continua", "Continue"], app: app, wait: 6)
            Diagnostics.log("stampante premuto Finito, Continua")
        } catch {
            Diagnostics.log("stampante Continua non premuto: \((error as? Problem)?.text ?? error.localizedDescription)")
            onFinished?("filamento-continua-\(Int(Date().timeIntervalSince1970))", "Signore, prema Continua sullo schermo della stampante.",
                        "Sir, please press Continue on the printer's screen.")
        }
    }

    // MARK: Printing

    /// Opens the model (or uses the one already open), slices it and reaches the send window.
    /// The actual send is a separate step: it uses filament and starts with nobody in front of it.
    func preparePrint(model: String?) async -> ToolOutcome {
        guard !busy else { return .result("Sto già lavorando in Bambu Studio.") }
        busy = true
        defer { busy = false }
        do {
            try await checkPrinterIsFree()
            if printer.status.filamentPresent == false { throw Problem("Il sensore non rileva filamento: prima va caricato.") }
            let app = try await model != nil ? studio(opening: model) : openProject()
            // The send window may already be there, from a request answered with no.
            let current = try await look(app)
            if let send = current.only(Self.sendLabels, in: Self.sendArea), current.isGreen(send) {
                return confirmation(current, model: model, app: app)
            }
            try await tap(["Prepara", "Prepare"], app: app, in: Self.tabBar, wait: 60)
            try await pause(1)
            // Print button already green: slicing is done and the project has not changed.
            let prepared = try await settledScreen(app: app, showing: Self.printLabels, in: Self.topRight, wait: 10)
            if !(prepared.only(Self.printLabels, in: Self.topRight).map(prepared.isGreen) ?? false) {
                try await waitForGreen(["Slice"], app: app, in: Self.topRight, seconds: 15, problem: "Bambu Studio non può fare lo slice: il piatto è vuoto o c'è un avviso da leggere.")
                try await tap(["Slice"], app: app, in: Self.topRight, wait: 10)
                Diagnostics.log("stampante slice avviato")
                try await waitForGreen(Self.printLabels, app: app, in: Self.topRight, seconds: 300, problem: "Lo slice non è finito in 5 minuti, o non è riuscito: controlla Bambu Studio.")
            }
            try await tap(Self.printLabels, app: app, in: Self.topRight, wait: 8)
            let dialog = try await waitForGreen(Self.sendLabels, app: app, in: Self.sendArea, seconds: 40, problem: "La finestra di invio non è pronta: Bambu Studio può aver segnalato un problema, controlla.")
            return confirmation(dialog, model: model, app: app)
        } catch let problem as Problem {
            return .result(problem.text)
        } catch {
            return .result(error.localizedDescription)
        }
    }

    private static let sendLabels = ["Invia", "Send"]
    private static let printLabels = ["Stampa", "Print"]

    private func confirmation(_ dialog: Screen, model: String?, app: NSRunningApplication) -> ToolOutcome {
        let details = Self.printDetails(dialog.words.map(\.text))
        let name = model.map { "\"\($0)\"" } ?? "il modello aperto"
        Diagnostics.log("stampante pronta all'invio \(details)")
        var action = PendingAction(summary: "Stampare \(name), piatto selezionato\(details.isEmpty ? "" : ", \(details)"), sul piatto della stampante che deve essere libero") { [weak self] in
            await self?.send(app: app) ?? "Non disponibile."
        }
        action.onCancel = { Self.closeSendWindow(of: app) }
        return .needsConfirmation(action)
    }

    /// With a no the send window closes, otherwise it stays on top and blocks everything else.
    private static func closeSendWindow(of app: NSRunningApplication) {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var title: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            guard let text = title as? String, text.hasPrefix("Invia") || text.hasPrefix("Send") else { continue }
            var button: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
                Diagnostics.log("stampante finestra di invio chiusa")
            }
        }
    }

    private func send(app: NSRunningApplication) async -> String {
        guard !busy else { return "Sto già lavorando in Bambu Studio." }
        busy = true
        defer { busy = false }
        do {
            try await bringToFront(app)
            try await tap(Self.sendLabels, app: app, in: Self.sendArea, wait: 5)
            let end = Date().addingTimeInterval(120)
            while Date() < end {
                if printer.status.isPrinting {
                    Diagnostics.log("stampante stampa avviata")
                    return "Stampa avviata: la stampante conferma."
                }
                try await pause(1)
            }
            return "Ho premuto Invia, ma dopo 2 minuti la stampante non ha iniziato: controlla Bambu Studio."
        } catch let problem as Problem {
            return problem.text
        } catch {
            return error.localizedDescription
        }
    }

    /// Duration and grams written in the send window, if they can be read.
    nonisolated private static func printDetails(_ words: [String]) -> String {
        let text = words.joined(separator: " ")
        let time = text.range(of: #"\b(\d+\s?d\s?)?(\d+\s?h\s?)?\d+\s?m(\s?\d+\s?s)?\b"#, options: .regularExpression).map { String(text[$0]) }
        let grams = text.range(of: #"\b\d+([.,]\d+)?\s?g\b"#, options: .regularExpression).map { String(text[$0]) }
        return [time.map { "durata \($0)" }, grams.map { "filamento \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Bambu Studio

    /// Opening a model, Bambu Studio launches a new copy of itself: work on that one. Without a model,
    /// on the last one opened.
    private func studio(opening model: String? = nil) async throws -> NSRunningApplication {
        let before = Self.instances()
        if let model {
            let result = await BambuActions.open(["model": model])
            guard result.hasPrefix("Aperto") else { throw Problem(result) }
            let end = Date().addingTimeInterval(30)
            while Date() < end {
                let known = Set(before.map(\.processIdentifier))
                if let new = Self.instances().last(where: { !known.contains($0.processIdentifier) }) {
                    try await waitForWindow(of: new)
                    try await bringToFront(new)
                    return new
                }
                try await pause(0.5)
            }
            throw Problem("Bambu Studio non ha aperto il modello.")
        }
        if let app = before.last {
            try await bringToFront(app)
            return app
        }
        let result = await BambuActions.open([:])
        guard result.hasPrefix("Aperto") else { throw Problem(result) }
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            if let app = Self.instances().last {
                try await waitForWindow(of: app)
                try await bringToFront(app)
                return app
            }
            try await pause(0.5)
        }
        throw Problem("Bambu Studio non si è aperto.")
    }

    /// The copy with a project open, the most recent: "Senza titolo" is an empty plate. With a
    /// send window open, its title is that: this is also an open project.
    private func openProject() async throws -> NSRunningApplication {
        for app in Self.instances().reversed() {
            guard let title = (try? Self.topWindow(pid: app.processIdentifier))?.title.lowercased() else { continue }
            if title.isEmpty || title.hasPrefix("senza titolo") || title.hasPrefix("untitled") { continue }
            try await bringToFront(app)
            return app
        }
        throw Problem("In Bambu Studio non c'è nessun modello aperto.")
    }

    private static func instances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            // Copies launched by Bambu Studio itself have no launch date: they come last.
            .sorted { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
    }

    private func waitForWindow(of app: NSRunningApplication) async throws {
        // From cold, Bambu Studio can take more than a minute.
        let end = Date().addingTimeInterval(120)
        while Date() < end {
            if (try? Self.topWindow(pid: app.processIdentifier)) != nil { return }
            try await pause(0.5)
        }
        throw Problem("Bambu Studio non ha aperto la finestra.")
    }

    private func bringToFront(_ app: NSRunningApplication) async throws {
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
            // From a background app activate() may not be enough: Accessibility is.
            app.activate()
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            try await pause(0.15)
        }
        throw Problem("Non riesco a portare davanti Bambu Studio: non clicco per non finire altrove.")
    }

    // MARK: Reading the screen

    private struct Word {
        let text: String
        /// In points, on screen.
        let rect: CGRect
    }

    private struct Screen {
        let words: [Word]
        let frame: CGRect
        let image: CGImage

        /// The label's rectangle, only if there is exactly one.
        func only(_ labels: [String], in region: CGRect? = nil) -> CGRect? {
            let found = all(labels, in: region)
            return found.count == 1 ? found[0] : nil
        }

        func all(_ labels: [String], in region: CGRect? = nil) -> [CGRect] {
            let wanted = Set(labels.map { $0.lowercased() })
            return words.filter { wanted.contains($0.text.lowercased()) }.map(\.rect).filter { rect in
                guard let region else { return true }
                let area = CGRect(x: frame.minX + region.minX * frame.width, y: frame.minY + region.minY * frame.height,
                                  width: region.width * frame.width, height: region.height * frame.height)
                return area.contains(CGPoint(x: rect.midX, y: rect.midY))
            }
        }

        /// Bambu Studio's active buttons are green, disabled ones grey.
        func isGreen(_ rect: CGRect) -> Bool {
            let scale = CGFloat(image.width) / frame.width
            let box = CGRect(x: (rect.minX - 12 - frame.minX) * scale, y: (rect.minY - frame.minY) * scale,
                             width: (rect.width + 24) * scale, height: rect.height * scale)
            guard let crop = image.cropping(to: box) else { return false }
            var pixel = [UInt8](repeating: 0, count: 4)
            let done = pixel.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            guard done else { return false }
            let (r, g, b) = (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
            return g > r * 1.3 && g > b * 1.3
        }
    }

    /// That app's front window: a warning open above the main window
    /// hides what is below, so nothing is searched elsewhere. Only this macOS list
    /// is in depth order; ScreenCaptureKit's changes.
    private static func topWindow(pid: pid_t) throws -> (frame: CGRect, title: String) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw Problem("Non riesco a leggere le finestre aperte.")
        }
        for window in list where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            guard let layer = window[kCGWindowLayer as String] as? Int, (0...8).contains(layer),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 150, frame.height > 80 else { continue }
            return (frame, window[kCGWindowName as String] as? String ?? "")
        }
        throw Problem("Bambu Studio non ha finestre visibili.")
    }

    /// The screen area of the window is captured, not the window alone: capturing a
    /// dialog, macOS includes the main window and shifts the proportions. This way it is also
    /// exactly what the user sees. JARVIS's windows stay out.
    private func look(_ app: NSRunningApplication) async throws -> Screen {
        let frame = try Self.topWindow(pid: app.processIdentifier).frame
        let image: CGImage
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) else {
                throw Problem("La finestra di Bambu Studio non è su nessuno schermo.")
            }
            let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int(frame.width * 2)
            config.height = Int(frame.height * 2)
            image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []),
                                                               configuration: config)
        } catch let problem as Problem {
            throw problem
        } catch {
            throw VisionActions.VisionError.captureFailed(error.localizedDescription)
        }
        return await Task.detached(priority: .userInitiated) { Self.read(image, frame: frame) }.value
    }

    nonisolated private static func read(_ image: CGImage, frame: CGRect) -> Screen {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["it-IT", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var words: [Word] = []
        for line in request.results ?? [] {
            guard let text = line.topCandidates(1).first else { continue }
            text.string.enumerateSubstrings(in: text.string.startIndex..., options: .byWords) { word, range, _, _ in
                guard let word, let box = (try? text.boundingBox(for: range))?.boundingBox else { return }
                words.append(Word(text: word, rect: CGRect(x: frame.minX + box.minX * frame.width,
                                                           y: frame.minY + (1 - box.maxY) * frame.height,
                                                           width: box.width * frame.width, height: box.height * frame.height)))
            }
        }
        return Screen(words: words, frame: frame, image: image)
    }

    /// Waits for the label to appear only once and stay still between two readings.
    @discardableResult
    private func settledScreen(app: NSRunningApplication, showing labels: [String], in region: CGRect? = nil, wait seconds: Double,
                               also check: ((Screen) -> Bool)? = nil) async throws -> Screen {
        let end = Date().addingTimeInterval(seconds)
        var last: CGRect?
        repeat {
            let screen = try await look(app)
            if let rect = screen.only(labels, in: region), check?(screen) ?? true {
                if let last, abs(last.midX - rect.midX) < 3, abs(last.midY - rect.midY) < 3 { return screen }
                last = rect
            } else {
                last = nil
            }
            try await pause(0.4)
        } while Date() < end
        if let warning = await unexpectedWindow(of: app) { throw Problem(warning) }
        throw Problem("Non trovo con sicurezza \"\(labels[0])\" in Bambu Studio: non premo nulla.")
    }

    @discardableResult
    /// A warning open above the main window is for the user: report it, do not close it.
    private func unexpectedWindow(of app: NSRunningApplication) async -> String? {
        guard let top = try? Self.topWindow(pid: app.processIdentifier), top.frame.width < 1000,
              let screen = try? await look(app) else { return nil }
        let text = screen.words.prefix(45).map(\.text).joined(separator: " ")
        return Security.external("avviso di Bambu Studio", text) + "\nNon lo chiudo da solo: leggilo all'utente, deve rispondere lui. Non ho premuto nulla."
    }

    private func waitForGreen(_ labels: [String], app: NSRunningApplication, in region: CGRect?, seconds: Double, problem: String) async throws -> Screen {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            let screen = try await look(app)
            if let rect = screen.only(labels, in: region), screen.isGreen(rect) { return screen }
            try await pause(1)
        } while Date() < end
        throw Problem(problem)
    }

    // MARK: Pressing

    /// Reads, hovers with the pointer, reads again and presses only if the label is still there.
    private func tap(_ labels: [String], app: NSRunningApplication, in region: CGRect? = nil, wait seconds: Double,
                     also check: ((Screen) -> Bool)? = nil) async throws {
        let screen = try await settledScreen(app: app, showing: labels, in: region, wait: seconds, also: check)
        guard let rect = screen.only(labels, in: region) else { throw Problem("Non trovo \"\(labels[0])\" in Bambu Studio.") }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        Self.move(to: point)
        try await pause(0.2)
        let again = try await look(app)
        guard let still = again.only(labels, in: region), abs(still.midX - point.x) < 3, abs(still.midY - point.y) < 3, check?(again) ?? true else {
            throw Problem("Il pannello di Bambu Studio si è spostato: non ho premuto \"\(labels[0])\".")
        }
        try await click(point, app: app)
        try await pause(0.4)
    }

    private func click(_ point: CGPoint, app: NSRunningApplication) async throws {
        guard !appControl.halted else { throw Problem("Interrotto dall'utente.") }
        guard AXIsProcessTrusted() else { throw Problem("Manca il permesso Accessibilità per JARVIS.") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw Problem("Bambu Studio non è più davanti: non clicco.")
        }
        guard Self.windowOwner(at: point) == app.processIdentifier else {
            throw Problem("C'è un'altra finestra sopra Bambu Studio in quel punto: non clicco.")
        }
        Self.move(to: point)
        try await pause(0.1)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await pause(0.06)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func move(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Whose window is on top at that point, transparent ones and the desktop excluded.
    static func windowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            return window[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
