import AppKit
import SwiftUI

/// NUCLEUS mode: only the reactor, in a small round window that lives
/// on the desktop, above the wallpaper but below every app window.
/// There is one for every display. Each can be dragged within its display (the
/// position is remembered per display), pulses when JARVIS listens or speaks,
/// and a click opens the full HUD on that display.
final class ReactorPanel: NSPanel {
    static let size: CGFloat = 170
    /// The normal level, always kept at its back (see `orderFrontRegardless`): above
    /// the wallpaper and the desktop widgets (level −1), below every app window.
    static let desktopLevel = NSWindow.Level.normal
    private var uncover: Timer?
    /// The display this NUCLEUS belongs to.
    let displayID: CGDirectDisplayID

    init(assistant: Assistant, screen: NSScreen, onOpen: @escaping (ReactorPanel) -> Void) {
        displayID = screen.displayID
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Self.desktopLevel
        // On every desktop, still during Mission Control, out of ⌘Tab.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        // macOS panels hide when the app loses focus:
        // the NUCLEUS instead must always stay on the desktop.
        hidesOnDeactivate = false
        let host = ReactorHostingView(rootView: CompactReactorView(assistant: assistant))
        host.onClick = { [weak self] in if let self { onOpen(self) } }
        host.assistant = assistant
        contentView = host
        // The widgets' central panels (Manual, Privacy) sit below the NUCLEUS: it steps aside.
        for name in ["hide", "show"] {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let panel = Unmanaged<ReactorPanel>.fromOpaque(observer).takeUnretainedValue()
                let covered = (name.rawValue as String).hasSuffix("hide")
                DispatchQueue.main.async { panel.setCovered(covered) }
            }, "\(jarvisBundleID).nucleo.\(name)" as CFString, nil, .deliverImmediately)
        }
        // Each display remembers its own position. The single NUCLEUS of older
        // versions keeps its place on the display where it was.
        let name = "JARVISReactor-\(displayID)"
        if !setFrameUsingName(name) && !(setFrameUsingName("JARVISReactor") && isOnOwnScreen) { placeAtCenter() }
        if !isOnOwnScreen { placeAtCenter() }
        setFrameAutosaveName(name)
    }

    /// The display of this NUCLEUS, if it is still connected.
    var ownScreen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    private var isOnOwnScreen: Bool {
        ownScreen?.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) ?? false
    }

    /// First time: at the centre of its display (below the menu bar), where
    /// the core of the user's wallpaper falls.
    func placeAtCenter() {
        guard let area = (ownScreen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: area.midX - Self.size / 2, y: area.midY - Self.size / 2))
    }

    /// Moves the NUCLEUS, but never past the edges of its own display: every display
    /// has its own, and one pushed onto another display ended up under the desktop widgets.
    func move(to point: NSPoint) {
        var origin = point
        if let area = ownScreen?.visibleFrame {
            origin.x = min(max(origin.x, area.minX), area.maxX - frame.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - frame.height)
        }
        if origin != frame.origin { setFrameOrigin(origin) }
    }

    /// After the displays change, each NUCLEUS goes back inside its own display.
    func keepOnOwnScreen() { move(to: frame.origin) }

    /// Called when its display is disconnected.
    func tearDown() {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        uncover?.invalidate()
        stacking?.invalidate()
        orderOut(nil)
    }

    /// Hidden while a central widget panel is open.
    private var widgetCovered = false
    /// Hidden while an app window it could not get behind covers it completely.
    private var appCovered = false
    private var stacking: Timer?

    private func applyVisibility() {
        let hidden = widgetCovered || appCovered
        animator().alphaValue = hidden ? 0 : 1
        ignoresMouseEvents = hidden
    }

    private func setCovered(_ covered: Bool) {
        widgetCovered = covered
        applyVisibility()
        // If the widget reloads with the panel open the "show" does not arrive: it comes back by itself.
        uncover?.invalidate()
        uncover = covered ? Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in self?.setCovered(false) } : nil
    }

    override var canBecomeKey: Bool { false }

    /// Shown at the back of the normal level: behind every app window, and above
    /// the desktop widgets (Übersicht uses level −1 for a full-screen window). At level −1
    /// the NUCLEUS shared that level and macOS kept the widgets in front of it: on the main
    /// display it stayed visible through them but could no longer be clicked or dragged.
    override func orderFrontRegardless() {
        level = Self.desktopLevel
        orderBack(nil)
        stacking?.invalidate()
        stacking = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStacking() }
        }
    }

    override func orderOut(_ sender: Any?) {
        stacking?.invalidate()
        stacking = nil
        super.orderOut(sender)
    }

    /// macOS does not always keep the NUCLEUS at the back: an app window enlarged to
    /// fill the screen ended up underneath it. If an app window overlapping it is
    /// below, it goes back behind; if macOS refuses and that window covers it
    /// completely, it hides until the window moves away.
    private func checkStacking() {
        guard isVisible else { return }
        let me = CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                        width: frame.width, height: frame.height)
        let pid = ProcessInfo.processInfo.processIdentifier
        func appWindowsBelow() -> [CGRect] {
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow, .excludeDesktopElements],
                                                        CGWindowID(windowNumber)) as? [[String: Any]] else { return [] }
            return list.compactMap { info in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowOwnerPID as String] as? Int32) != pid,
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                      let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 40, h > 40
                else { return nil }
                let r = CGRect(x: x, y: y, width: w, height: h)
                return r.intersects(me) ? r : nil
            }
        }
        var below = appWindowsBelow()
        if !below.isEmpty {
            orderBack(nil)
            below = appWindowsBelow()
        }
        let hide = below.contains { $0.contains(me) }
        if hide != appCovered {
            appCovered = hide
            applyVisibility()
        }
    }
}

/// Tells a drag (moves the window) from a click (opens the HUD).
/// With the right button it shows a small menu.
final class ReactorHostingView: NSHostingView<CompactReactorView> {
    var onClick: (() -> Void)?
    weak var assistant: Assistant?
    private var start: (mouse: NSPoint, origin: NSPoint)?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        start = window.map { (NSEvent.mouseLocation, $0.frame.origin) }
        dragging = false
    }

    /// After a few points of movement the NUCLEUS follows the mouse, stopping at the
    /// edges of its display (a macOS window drag would let it cross onto another one).
    override func mouseDragged(with event: NSEvent) {
        guard let start, let panel = window as? ReactorPanel else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        guard dragging || abs(dx) > 3 || abs(dy) > 3 else { return }
        dragging = true
        panel.move(to: NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            // Back in front of the desktop widgets, which share its level.
            window?.orderFrontRegardless()
        } else {
            onClick?()
        }
        start = nil
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Apri HUD", action: #selector(openHUD), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Parla (⌃⌥Spazio)", action: #selector(talk), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Nuova conversazione", action: #selector(reset), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Esci da JARVIS", action: #selector(quit), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openHUD() { onClick?() }
    @MainActor @objc private func talk() { assistant?.pushToTalk() }
    @MainActor @objc private func reset() { assistant?.resetConversation() }
    @objc private func quit() { NSApp.terminate(nil) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct CompactReactorView: View {
    @ObservedObject var assistant: Assistant

    var body: some View {
        ZStack {
            if assistant.config.nucleusBackdrop {
                // Dark shaded disc: useful on light wallpapers or ones full of windows.
                Circle().fill(RadialGradient(colors: [HUD.background.opacity(0.92), HUD.background.opacity(0.75), .clear],
                                             center: .center, startRadius: 0, endRadius: ReactorPanel.size / 2))
            } else {
                // Almost invisible, but enough for clicks on the whole circle
                // to reach the NUCLEUS instead of passing to the wallpaper.
                Circle().fill(Color.black.opacity(0.012))
            }
            ReactorView(assistant: assistant, compact: true, paused: !assistant.compactVisible)
                .padding(8)
        }
        .frame(width: ReactorPanel.size, height: ReactorPanel.size)
        .contentShape(Circle())
        .help("NUCLEO di JARVIS · clic per aprire l'HUD, trascina per spostare")
    }
}

extension NSScreen {
    /// Stable identifier of the display, used to give each one its own NUCLEUS.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
