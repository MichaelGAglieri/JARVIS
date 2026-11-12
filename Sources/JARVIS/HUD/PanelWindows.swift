import AppKit
import SwiftUI

/// JARVIS's panels as separate windows (1.30.17, user request of 11 November): they open from the
/// menu bar ("Schede", top left, and the JARVIS icon, top right), they can be moved anywhere
/// and they work both with the neural orb and with the SATELLITE.
/// Each window remembers where it was left; the open ones reopen at the next launch.
@MainActor
final class PanelWindows: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var open: Set<HUDDrawer> = []
    private let assistant: Assistant
    /// Where JARVIS is now (HUD or SATELLITE): panels never moved open beside it.
    var anchor: () -> NSRect? = { nil }
    private var windows: [HUDDrawer: NSPanel] = [:]

    static let width: CGFloat = 330
    private static let gap: CGFloat = 10
    private static let savedKey = "openPanels"

    init(assistant: Assistant) {
        self.assistant = assistant
        super.init()
    }

    func isOpen(_ drawer: HUDDrawer) -> Bool { open.contains(drawer) }

    func set(_ drawer: HUDDrawer, open shouldOpen: Bool) {
        shouldOpen ? show(drawer) : windows[drawer]?.close()
    }

    func openAll() { HUDDrawer.allCases.forEach(show) }
    func closeAll() { HUDDrawer.allCases.forEach { windows[$0]?.close() } }

    /// The panels open when JARVIS last quit.
    func restore() {
        let names = UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? []
        names.compactMap(HUDDrawer.init(rawValue:)).forEach(show)
    }

    private func show(_ drawer: HUDDrawer) {
        let window = windows[drawer] ?? makeWindow(drawer)
        windows[drawer] = window
        window.orderFrontRegardless()
        open.insert(drawer)
        save()
    }

    private func save() {
        UserDefaults.standard.set(open.map(\.rawValue).sorted(), forKey: Self.savedKey)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel,
              let drawer = windows.first(where: { $0.value === window })?.key else { return }
        open.remove(drawer)
        save()
    }

    // MARK: Windows

    private static func isTall(_ drawer: HUDDrawer) -> Bool { [.transcript, .log, .thought].contains(drawer) }

    private func makeWindow(_ drawer: HUDDrawer) -> NSPanel {
        let size = initialSize(drawer)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "JARVIS · \(drawer.title)"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 260, height: 120)
        panel.delegate = self
        let host = NSHostingView(rootView: PanelChrome(drawer: drawer, assistant: assistant))
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(size)

        let name = "JARVISScheda.\(drawer.rawValue)"
        if !panel.setFrameUsingName(name) { panel.setFrameOrigin(defaultOrigin(drawer, size: size)) }
        panel.setFrameAutosaveName(name)
        return panel
    }

    private func initialSize(_ drawer: HUDDrawer) -> NSSize {
        switch drawer {
        case .transcript: return NSSize(width: Self.width, height: 380)
        case .log: return NSSize(width: Self.width, height: 290)
        case .thought: return NSSize(width: Self.width, height: 320)
        default:
            let probe = NSHostingView(rootView: HUDDrawerContent(drawer: drawer, assistant: assistant, activity: assistant.activity)
                .frame(width: Self.width).fixedSize(horizontal: false, vertical: true))
            return NSSize(width: Self.width, height: probe.fittingSize.height + PanelChrome.topInset)
        }
    }

    /// The first time, beside JARVIS like the old drawers: histories on the left, the rest on the right,
    /// one under the other in the usual order. A column with no room on its side (JARVIS near
    /// the edge of the screen) goes next to the other one, so no panel covers another.
    private func defaultOrigin(_ drawer: HUDDrawer, size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = anchor() ?? NSRect(x: area.midX - 150, y: area.midY - 150, width: 300, height: 300)
        let step = Self.width + Self.gap
        var leftX = anchor.minX - step
        var rightX = anchor.maxX + Self.gap
        if rightX + Self.width > area.maxX { rightX = leftX - step }
        if leftX < area.minX { leftX = max(rightX, anchor.maxX + Self.gap) + (rightX > anchor.maxX ? step : 0) }
        if rightX < area.minX { rightX = leftX + step }

        let column = HUDDrawer.allCases.filter { $0.isLeft == drawer.isLeft }
        let heights = column.map { initialSize($0).height }
        let total = heights.reduce(0, +) + Self.gap * CGFloat(column.count - 1)
        let top = min(area.maxY, max(anchor.maxY, area.minY + total))
        let index = column.firstIndex(of: drawer) ?? 0
        let offset = heights.prefix(index).reduce(0, +) + Self.gap * CGFloat(index)
        var origin = NSPoint(x: drawer.isLeft ? leftX : rightX, y: top - offset - size.height)
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return origin
    }
}

/// The HUD look around a panel: dark glass, room on top for the close button and for dragging.
private struct PanelChrome: View {
    static let topInset: CGFloat = 22
    let drawer: HUDDrawer
    @ObservedObject var assistant: Assistant

    var body: some View {
        VStack(spacing: 0) {
            HUDDrawerContent(drawer: drawer, assistant: assistant, activity: assistant.activity)
            Spacer(minLength: 0)
        }
        .padding(.top, Self.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(HUD.background.opacity(0.97), in: HUD.panelShape)
        .ignoresSafeArea()
    }
}

/// The "Schede" rows, the same in the top-left menu and in the JARVIS icon's menu.
struct PanelMenuItems: View {
    @ObservedObject var panels: PanelWindows

    var body: some View {
        ForEach(HUDDrawer.allCases) { drawer in
            Toggle(drawer.title, isOn: Binding(get: { panels.isOpen(drawer) },
                                               set: { panels.set(drawer, open: $0) }))
        }
        Divider()
        Button("Apri tutte") { panels.openAll() }
        Button("Chiudi tutte") { panels.closeAll() }
    }
}
