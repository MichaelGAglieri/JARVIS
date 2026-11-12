import AppKit
import ServiceManagement
import SwiftUI

/// With `--index-notes` this same program builds the notes index and quits.
@main
enum Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--index-notes") {
            NotesIndexer.run(folders: Array(arguments[(flag + 1)...]))
        }
        // To try the search from the command line, without opening the app.
        if let flag = arguments.firstIndex(of: "--search-notes"), arguments.count > flag + 1 {
            print(NotesSearch.search(query: arguments[flag + 1], subject: arguments.count > flag + 2 ? arguments[flag + 2] : nil))
            exit(0)
        }
        JarvisApp.main()
    }
}

struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Button("Mostra HUD") { delegate.showHUD() }
            Button("Riduci a SATELLITE") { delegate.showCompact() }
            Button("Parla (⌃⌥Spazio)") { delegate.assistant.pushToTalk() }
            Button("Nuova conversazione") { delegate.assistant.resetConversation() }
            Button(delegate.assistant.privacyMode ? "Esci dalla modalità privacy (⌃⌥P)" : "Modalità privacy (⌃⌥P)") {
                delegate.assistant.togglePrivacy()
            }
            Button(delegate.assistant.brain == .claude ? "Torna al nucleo locale" : "Usa Claude") {
                delegate.assistant.setBrain(delegate.assistant.brain == .claude ? .local : .claude)
            }
            Divider()
            Section("Schede") { PanelMenuItems(panels: delegate.panels) }
            Divider()
            SettingsLink { Text("Impostazioni…") }
            Divider()
            Button("Esci da JARVIS") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "circle.circle")
        }
        // The same rows in the menu bar on the left, while JARVIS is the frontmost app.
        .commands {
            CommandMenu("Schede") { PanelMenuItems(panels: delegate.panels) }
        }

        Settings {
            SettingsView(assistant: delegate.assistant)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let assistant = Assistant()
    /// The panels (Frasi, Registro, …) as movable windows, opened from the menu bar.
    lazy var panels = PanelWindows(assistant: assistant)
    private var window: HUDWindow?
    /// One NUCLEUS for every connected display.
    private var reactors: [CGDirectDisplayID: ReactorPanel] = [:]
    /// The NUCLEUS hidden under the open HUD: the HUD grew out of it.
    private var hudNucleus: ReactorPanel?
    /// Prevents App Nap from slowing JARVIS down in standby: it must keep
    /// listening for "Jarvis" and keep the NUCLEUS in front of the wallpaper.
    private var awake: NSObjectProtocol?
    /// The chosen mode (full HUD or NUCLEUS only) also holds at the next launch.
    private var compactMode: Bool {
        get { UserDefaults.standard.bool(forKey: "compactMode") }
        set { UserDefaults.standard.set(newValue, forKey: "compactMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hud = HUDView(assistant: assistant,
                          onCompact: { [weak self] in self?.showCompact() },
                          onWindowDrag: { [weak self] ended in self?.window?.followMouse(ended: ended) })
        let window = HUDWindow(content: hud)
        self.window = window
        updateReactors()
        // Displays connected, disconnected or rearranged: one NUCLEUS each, always.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateReactors() }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                self.assistant.hudVisible = window.occlusionState.contains(.visible)
            }
        }

        // Windows are shown only after registering the visibility observers,
        // otherwise the first change is lost and the animation stays still.
        reactors.values.forEach { $0.orderFrontRegardless() }
        if !compactMode, let nucleus = nucleus(on: NSScreen.main) {
            // At launch the large reactor sits exactly over the NUCLEUS of the main display.
            window.place(reactorCenter: NSPoint(x: nucleus.frame.midX, y: nucleus.frame.midY))
            nucleus.orderOut(nil)
            hudNucleus = nucleus
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        updateCompactVisible()
        panels.anchor = { [weak self] in self?.jarvisFrame() }
        panels.restore()
        assistant.boot()
        enableLaunchAtLoginOnce()
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                      reason: "JARVIS ascolta la parola Jarvis")

        // When it hears "Jarvis" the HUD comes to the front, without stealing the keyboard.
        // Not in NUCLEUS mode: it stays on the desktop and reacts there.
        NotificationCenter.default.addObserver(forName: .jarvisActivated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.compactMode else { return }
                self.window?.orderFrontRegardless()
            }
        }
    }

    /// Where JARVIS is on screen now: the HUD if open, otherwise the SATELLITE of the main display.
    private func jarvisFrame() -> NSRect? {
        if let window, window.isVisible { return window.frame }
        return nucleus(on: NSScreen.main)?.frame
    }

    /// On the first run from /Applications JARVIS adds itself to the login
    /// items, so it starts when the Mac turns on. It can be turned off in the settings
    /// (JARVIS's or macOS's) and from then on the choice is respected.
    private func enableLaunchAtLoginOnce() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        } catch {
            NSLog("JARVIS: impossibile aggiungere l'elemento di login: \(error.localizedDescription)")
        }
    }

    /// Creates a NUCLEUS for each new display and removes those of disconnected ones.
    private func updateReactors() {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for (id, panel) in reactors where !ids.contains(id) {
            if hudNucleus === panel { hudNucleus = nil }
            panel.tearDown()
            reactors[id] = nil
        }
        for screen in screens where reactors[screen.displayID] == nil {
            let panel = ReactorPanel(assistant: assistant, screen: screen) { [weak self] nucleus in self?.showHUD(from: nucleus) }
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel,
                                                   queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateCompactVisible() }
            }
            reactors[screen.displayID] = panel
            // A display connected while running shows its NUCLEUS at once.
            if window != nil { panel.orderFrontRegardless() }
        }
        for panel in reactors.values where panel.isVisible { panel.keepOnOwnScreen() }
    }

    /// The small reactors animate only while at least one of them can be seen.
    private func updateCompactVisible() {
        assistant.compactVisible = reactors.values.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    private func nucleus(on screen: NSScreen?) -> ReactorPanel? {
        screen.flatMap { reactors[$0.displayID] } ?? reactors.values.first
    }

    /// The display under the mouse pointer: menu bar and Dock open the HUD there.
    private var screenAtMouse: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    /// Opens the HUD from a NUCLEUS. If the HUD is already open on another display,
    /// it first shrinks into the NUCLEUS of that display, then opens here.
    func showHUD(from source: ReactorPanel? = nil) {
        guard let window else { return }
        if window.isVisible {
            compactMode = false
            guard let source, let current = hudNucleus ?? nucleus(on: window.screen), source !== current else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                return
            }
            showCompact { [weak self] in self?.openHUD(from: source) }
            return
        }
        openHUD(from: source ?? nucleus(on: screenAtMouse))
    }

    /// From NUCLEUS to HUD: the window grows starting from the NUCLEUS.
    private func openHUD(from reactor: ReactorPanel?) {
        compactMode = false
        guard let window, let reactor, reactor.isVisible, !window.isVisible else {
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        hudNucleus = reactor
        let center = NSPoint(x: reactor.frame.midX, y: reactor.frame.midY)
        // The large reactor opens exactly around the NUCLEUS, like a magnification of it.
        window.place(reactorCenter: center)
        zoom(window, toward: center, opening: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            reactor.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                // Another click may have opened the HUD elsewhere in the meantime.
                if self.hudNucleus === reactor { reactor.orderOut(nil) }
                reactor.alphaValue = 1
                self.updateCompactVisible()
            }
        }
        NSApp.activate()
    }

    /// From HUD to NUCLEUS: the window shrinks into the NUCLEUS of the display it is on.
    /// `then` runs when the NUCLEUS is back (used to reopen the HUD on another display).
    func showCompact(then: (() -> Void)? = nil) {
        compactMode = true
        let reactor = nucleus(on: window?.screen) ?? hudNucleus
        // Every other NUCLEUS is back too: one per display, always.
        for panel in reactors.values where panel !== reactor && !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        hudNucleus = nil
        guard let window, let reactor, window.isVisible else {
            self.window?.orderOut(nil)
            reactor?.orderFrontRegardless()
            updateCompactVisible()
            then?()
            return
        }
        reactor.alphaValue = 0
        reactor.orderFrontRegardless()
        updateCompactVisible()
        let center = NSPoint(x: reactor.frame.midX, y: reactor.frame.midY)
        zoom(window, toward: center, opening: false)
        // The NUCLEUS appears while the HUD finishes shrinking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                reactor.animator().alphaValue = 1
            }
        }
        if let then {
            // After the shrinking (0.16 s) has hidden the window, so the two animations do not overlap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { then() }
        }
    }

    /// "Mac style" animation: the HUD content shrinks towards (or grows
    /// from) a point of the screen and fades. The live HUD is animated, not a
    /// snapshot of it, so the reactor keeps spinning during the effect.
    private func zoom(_ window: NSWindow, toward screenPoint: NSPoint, opening: Bool) {
        guard let view = window.contentView else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        let bounds = view.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let target = window.convertPoint(fromScreen: screenPoint)
        let toward = CGPoint(x: target.x - bounds.midX, y: target.y - bounds.midY)
        let scale = ReactorPanel.size / HUDView.reactorSize

        /// One phase of the animation: movement towards the NUCLEUS (0…1), scale and tilt.
        func stage(move: CGFloat, sx: CGFloat, sy: CGFloat, tilt: CGFloat) -> CATransform3D {
            var t = CATransform3DIdentity
            t.m34 = -1 / 900
            t = CATransform3DTranslate(t, toward.x * move, toward.y * move, 0)
            t = CATransform3DRotate(t, tilt, 0, 1, 0)
            return CATransform3DScale(t, sx, sy, 1)
        }
        // Proportional shrinking, with no funnel and no tilt.
        let small = stage(move: 1, sx: scale, sy: scale, tilt: 0)
        let frames = [
            CATransform3DIdentity,
            stage(move: 0.15, sx: 0.85, sy: 0.85, tilt: 0),
            stage(move: 0.45, sx: 0.55, sy: 0.55, tilt: 0),
            stage(move: 0.80, sx: 0.25, sy: 0.25, tilt: 0),
            small,
        ]

        let duration = 0.16
        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = (opening ? frames.reversed() : frames).map { NSValue(caTransform3D: $0) }
        transform.keyTimes = [0, 0.22, 0.5, 0.8, 1]
        transform.timingFunctions = Array(repeating: CAMediaTimingFunction(name: opening ? .easeOut : .easeIn), count: 4)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        // It stays clearly visible during the funnel and fades only in the last stretch.
        fade.values = opening ? [0.0, 0.85, 1.0, 1.0] : [1.0, 1.0, 0.85, 0.0]
        fade.keyTimes = opening ? [0, 0.25, 0.6, 1] : [0, 0.4, 0.75, 1]
        for animation in [transform, fade] {
            animation.duration = duration
        }

        if opening {
            layer.transform = small
            layer.opacity = 0
            window.makeKeyAndOrderFront(nil)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            Task { @MainActor in
                if !opening { window.orderOut(nil) }
                layer.transform = CATransform3DIdentity
                layer.opacity = 1
            }
        }
        layer.add(transform, forKey: "jarvisZoom")
        layer.add(fade, forKey: "jarvisFade")
        layer.transform = opening ? CATransform3DIdentity : small
        layer.opacity = opening ? 1 : 0
        CATransaction.commit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHUD()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        assistant.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Transparent window, without title bar and shadow: only the reactor and its glow
/// show. Where it is fully transparent, clicks pass through to the desktop.
/// The icons respond to the first click even if JARVIS is not the frontmost app.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HUDWindow: NSWindow {
    // No title bar: macOS's hidden one took the clicks on the X, in the top right corner.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(origin: .zero, size: HUDView.size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Otherwise in transparent spots the mouse goes through the window and the icons do not feel it.
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace]
        let host = FirstClickHostingView(rootView: content)
        // No system margins and no automatic resizing of the window.
        host.safeAreaRegions = []
        host.sizingOptions = []
        contentView = host
        setFrame(NSRect(origin: .zero, size: HUDView.size), display: false)
        center()
    }

    /// Puts the reactor's centre at that point of the screen, staying inside the screen.
    func place(reactorCenter point: NSPoint) {
        var origin = NSPoint(x: point.x - HUDView.size.width / 2, y: point.y - (HUDView.size.height - HUDView.reactorCenterFromTop))
        if let area = (NSScreen.screens.first { $0.frame.contains(point) } ?? screen)?.visibleFrame {
            origin.x = min(max(origin.x, area.minX), area.maxX - frame.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - frame.height)
        }
        setFrameOrigin(origin)
    }

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// The window follows the mouse: only how far it moved since the drag started counts.
    func followMouse(ended: Bool) {
        guard !ended else { dragStart = nil; return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, frame.origin)
        dragStart = start
        setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
