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
            Button("Riduci a NUCLEO") { delegate.showCompact() }
            Button("Parla (⌃⌥Spazio)") { delegate.assistant.pushToTalk() }
            Button("Nuova conversazione") { delegate.assistant.resetConversation() }
            Button(delegate.assistant.privacyMode ? "Esci dalla modalità privacy (⌃⌥P)" : "Modalità privacy (⌃⌥P)") {
                delegate.assistant.togglePrivacy()
            }
            Button(delegate.assistant.brain == .claude ? "Torna al nucleo locale" : "Usa Claude") {
                delegate.assistant.setBrain(delegate.assistant.brain == .claude ? .local : .claude)
            }
            Divider()
            SettingsLink { Text("Impostazioni…") }
            Divider()
            Button("Esci da JARVIS") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "circle.circle")
        }

        Settings {
            SettingsView(assistant: delegate.assistant)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let assistant = Assistant()
    private var window: HUDWindow?
    private var reactor: ReactorPanel?
    /// Prevents App Nap from slowing JARVIS down in standby: it must keep
    /// listening for "Jarvis" and keep the NUCLEUS in front of the wallpaper.
    private var awake: NSObjectProtocol?
    /// The chosen mode (full HUD or NUCLEUS only) also holds at the next launch.
    private var compactMode: Bool {
        get { UserDefaults.standard.bool(forKey: "compactMode") }
        set { UserDefaults.standard.set(newValue, forKey: "compactMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hud = HUDView(assistant: assistant, activity: assistant.activity,
                          onClose: { [weak self] in self?.window?.orderOut(nil) },
                          onCompact: { [weak self] in self?.showCompact() },
                          onDrawerChange: { [weak self] left, right in self?.window?.setDrawers(left: left, right: right) },
                          onWindowDrag: { [weak self] ended in self?.window?.followMouse(ended: ended) })
        let window = HUDWindow(content: hud)
        self.window = window
        let reactor = ReactorPanel(assistant: assistant) { [weak self] in self?.showHUD() }
        self.reactor = reactor
        // At launch too, the large reactor sits exactly over the NUCLEUS.
        window.place(reactorCenter: NSPoint(x: reactor.frame.midX, y: reactor.frame.midY))

        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                self.assistant.hudVisible = window.occlusionState.contains(.visible)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: reactor,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let reactor = self.reactor else { return }
                self.assistant.compactVisible = reactor.occlusionState.contains(.visible)
            }
        }

        // Windows are shown only after registering the visibility observers,
        // otherwise the first change is lost and the animation stays still.
        if compactMode { showCompact() } else { showHUD() }
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

    /// From NUCLEUS to HUD: the window grows starting from the NUCLEUS.
    func showHUD() {
        compactMode = false
        guard let window, let reactor, reactor.isVisible, !window.isVisible else {
            reactor?.orderOut(nil)
            assistant.compactVisible = false
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let center = NSPoint(x: reactor.frame.midX, y: reactor.frame.midY)
        // The large reactor opens exactly around the NUCLEUS, like a magnification of it.
        window.place(reactorCenter: center)
        zoom(window, toward: center, opening: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            reactor.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                reactor.orderOut(nil)
                reactor.alphaValue = 1
                self.assistant.compactVisible = false
            }
        }
        NSApp.activate()
    }

    /// From HUD to NUCLEUS: the window shrinks into the NUCLEUS.
    func showCompact() {
        compactMode = true
        guard let window, let reactor, window.isVisible else {
            self.window?.orderOut(nil)
            reactor?.orderFrontRegardless()
            assistant.compactVisible = true
            return
        }
        reactor.alphaValue = 0
        reactor.orderFrontRegardless()
        assistant.compactVisible = true
        let center = NSPoint(x: reactor.frame.midX, y: reactor.frame.midY)
        zoom(window, toward: center, opening: false)
        // The NUCLEUS appears while the HUD finishes shrinking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                reactor.animator().alphaValue = 1
            }
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
        guard !ended else { dragStart = nil; homeReactorX = nil; return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, frame.origin)
        dragStart = start
        setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    /// How much space the panels to the left of the reactor take now.
    private var leftWidth: CGFloat = 0
    /// Where the reactor was before opening the panels, if it was moved to fit them on screen.
    private var homeReactorX: CGFloat?

    /// Widens the window on the sides with an open panel: the reactor does not move,
    /// unless the panels would go off screen. With all closed, it goes back to its place.
    func setDrawers(left: Bool, right: Bool) {
        let newLeft = left ? HUDView.drawerWidth : 0
        let width = HUDView.size.width + newLeft + (right ? HUDView.drawerWidth : 0)
        var reactorX = frame.minX + leftWidth + HUDView.size.width / 2
        if left || right {
            if homeReactorX == nil { homeReactorX = reactorX }
        } else if let home = homeReactorX {
            reactorX = home
            homeReactorX = nil
        }
        var target = NSRect(x: reactorX - HUDView.size.width / 2 - newLeft, y: frame.minY, width: width, height: frame.height)
        if let area = screen?.visibleFrame {
            target.origin.x = max(area.minX, min(target.minX, area.maxX - target.width))
        }
        leftWidth = newLeft
        setFrame(target, display: true, animate: false)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
