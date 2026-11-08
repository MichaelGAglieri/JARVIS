import AppKit
import SwiftUI

/// NUCLEUS mode: only the reactor, in a small round window that lives
/// on the desktop, above the wallpaper but below every app window.
/// It can be dragged anywhere (the position is remembered), pulses when
/// JARVIS listens or speaks, and a click reopens the full HUD.
final class ReactorPanel: NSPanel {
    static let size: CGFloat = 170
    /// Level −1: just below app windows (level 0) but above the wallpaper
    /// and desktop widgets like Übersicht, which uses exactly level −1
    /// for a full-screen window: any lower and the NUCLEUS would stay hidden.
    static let desktopLevel = NSWindow.Level(rawValue: -1)
    private var keepVisible: Timer?
    private var uncover: Timer?

    init(assistant: Assistant, onOpen: @escaping () -> Void) {
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
        host.onClick = onOpen
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
        if !setFrameUsingName("JARVISReactor") { placeAtCenter() }
        setFrameAutosaveName("JARVISReactor")
    }

    /// First time: at the centre of the screen (below the menu bar), where
    /// the core of the user's wallpaper falls.
    func placeAtCenter() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.midX - Self.size / 2, y: screen.midY - Self.size / 2))
    }

    private func setCovered(_ covered: Bool) {
        animator().alphaValue = covered ? 0 : 1
        ignoresMouseEvents = covered
        // If the widget reloads with the panel open the "show" does not arrive: it comes back by itself.
        uncover?.invalidate()
        uncover = covered ? Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in self?.setCovered(false) } : nil
    }

    override var canBecomeKey: Bool { false }

    /// AppKit resets the level to "normal" when the window is shown:
    /// it is set again every time. Then, every 3 seconds, the NUCLEUS comes back in front
    /// of the other level −1 elements (never above apps): if a desktop widget
    /// redraws over it, it reappears by itself.
    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        level = Self.desktopLevel
        keepVisible?.invalidate()
        keepVisible = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.order(.above, relativeTo: 0)
        }
    }

    override func orderOut(_ sender: Any?) {
        keepVisible?.invalidate()
        keepVisible = nil
        super.orderOut(sender)
    }
}

/// Tells a drag (moves the window) from a click (opens the HUD).
/// With the right button it shows a small menu.
final class ReactorHostingView: NSHostingView<CompactReactorView> {
    var onClick: (() -> Void)?
    weak var assistant: Assistant?
    private var downEvent: NSEvent?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
    }

    /// As soon as the mouse moves a few points, the drag goes to macOS
    /// (the same used for every window): smooth and precise.
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = downEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard abs(dx) > 3 || abs(dy) > 3 else { return }
        dragging = true
        window?.performDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onClick?() }
        downEvent = nil
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
