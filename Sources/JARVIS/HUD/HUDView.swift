import SwiftUI

/// The drop-down panels: they open one at a time or all together, each in its place around the reactor,
/// which stays still and fully visible.
enum HUDDrawer: String, CaseIterable, Identifiable {
    case transcript, log, activity, modules, protocolPanel
    var id: String { rawValue }
    /// Histories on the left, controls and state on the right.
    var isLeft: Bool { [.transcript, .log, .activity].contains(self) }
    var symbol: String {
        switch self {
        case .transcript: return "text.bubble"
        case .log: return "list.bullet.rectangle"
        case .activity: return "clock"
        case .modules: return "square.stack.3d.up"
        case .protocolPanel: return "slider.horizontal.3"
        }
    }
    var title: String {
        switch self {
        case .transcript: return "Frasi"
        case .log: return "Registro"
        case .activity: return "Attività"
        case .modules: return "Moduli"
        case .protocolPanel: return "Protocollo"
        }
    }
}

/// Main screen: only the reactor and its state. The icons appear
/// when hovering with the mouse and the rest lives in the panels.
struct HUDView: View {
    static let size = CGSize(width: 600, height: 600)
    static let drawerWidth: CGFloat = 320
    static let reactorSize: CGFloat = 490
    /// The reactor sits at the centre of the window.
    static let reactorCenterFromTop: CGFloat = 300
    /// The buttons sit on a circle just larger than the reactor.
    static let ringRadius: CGFloat = 272
    static let ringStep = 14.0

    @ObservedObject var assistant: Assistant
    @ObservedObject var activity: ActivityTracker
    @Environment(\.openSettings) private var openSettings
    var onClose: () -> Void
    var onCompact: () -> Void = {}
    /// The window widens on the sides where a panel is open.
    var onDrawerChange: (_ left: Bool, _ right: Bool) -> Void = { _, _ in }
    /// Reactor drag in progress; `true` when it ends.
    var onWindowDrag: (Bool) -> Void = { _ in }

    @State private var drawers: Set<HUDDrawer> = []
    @State private var hovering = false
    @State private var hoveringToolbar = false
    private var showToolbar: Bool { hovering || hoveringToolbar || !drawers.isEmpty }
    private var leftOpen: Bool { drawers.contains { $0.isLeft } }
    private var rightOpen: Bool { drawers.contains { !$0.isLeft } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NucleusHalo()
                .frame(width: Self.size.width, height: Self.size.height)
                .offset(x: leftOpen ? Self.drawerWidth : 0)
            HStack(spacing: 0) {
                if leftOpen { drawerColumn(left: true) }
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.reactorCenterFromTop - Self.reactorSize / 2)
                    ReactorView(assistant: assistant, paused: !assistant.hudVisible)
                        .frame(width: Self.reactorSize, height: Self.reactorSize)
                    stateLabel.frame(height: 50)
                }
                .frame(width: Self.size.width, height: Self.size.height)
                // The window moves by dragging the reactor; a simple click does not move it.
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in onWindowDrag(false) }
                    .onEnded { _ in onWindowDrag(true) })
                if rightOpen { drawerColumn(left: false) }
            }
            iconRing
                .frame(width: Self.size.width, height: Self.size.height)
                .offset(x: leftOpen ? Self.drawerWidth : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .onChange(of: drawers) { onDrawerChange(leftOpen, rightOpen) }
    }

    // MARK: Sections

    /// Panels on the left, window controls on the right, on the same circle around
    /// the reactor. They stay clickable even when hidden: they appear on hover.
    private var iconRing: some View {
        ZStack {
            ForEach(Array(HUDDrawer.allCases.enumerated()), id: \.element) { index, item in
                ringIcon(item.symbol, active: drawers.contains(item), left: true, slot: Double(index) - 2) {
                    if drawers.contains(item) { drawers.remove(item) } else { drawers.insert(item) }
                }
                .help(item.title)
            }
            ringIcon("xmark", left: false, slot: -1) { onClose() }
                .help("Nascondi")
            ringIcon("gearshape", left: false, slot: 0) { openSettings() }
                .help("Impostazioni")
            ringIcon("circle.circle", left: false, slot: 1) {
                drawers = []
                onCompact()
            }
            .help("Riduci al NUCLEO sulla scrivania")
            ringIcon("square.grid.2x2", active: drawers.count == HUDDrawer.allCases.count, left: false, slot: 2) {
                drawers = drawers.count == HUDDrawer.allCases.count ? [] : Set(HUDDrawer.allCases)
            }
            .help("Apri o chiudi tutte le schede")
        }
    }

    /// `slot` is the place on the circle: 0 at the height of the centre, negative upwards.
    private func ringIcon(_ symbol: String, active: Bool = false, left: Bool, slot: Double, action: @escaping () -> Void) -> some View {
        let angle = slot * Self.ringStep * .pi / 180
        let center = Self.reactorCenterFromTop
        let dx = Self.ringRadius * cos(angle)
        return HUDIconButton(symbol: symbol, active: active, shown: showToolbar,
                             onHoverChange: { hoveringToolbar = $0 }, action: action)
            .position(x: center + (left ? -dx : dx), y: center + Self.ringRadius * sin(angle))
    }

    /// A column of panels, always in the same order: Phrases and Log share
    /// the free space, the others are as tall as needed.
    private func drawerColumn(left: Bool) -> some View {
        let open = HUDDrawer.allCases.filter { $0.isLeft == left && drawers.contains($0) }
        let hasTall = open.contains { $0 == .transcript || $0 == .log }
        return VStack(spacing: 10) {
            if !hasTall { Spacer(minLength: 0) }
            ForEach(open) { drawerPanel($0).background(HUD.background.opacity(0.82), in: HUD.panelShape) }
            if !hasTall { Spacer(minLength: 0) }
        }
        .padding(EdgeInsets(top: 14, leading: left ? 14 : 0, bottom: 14, trailing: left ? 0 : 14))
        .frame(width: Self.drawerWidth, height: Self.size.height)
    }

    @ViewBuilder
    private func drawerPanel(_ drawer: HUDDrawer) -> some View {
        switch drawer {
        case .transcript: transcriptPanel
        case .log: logPanel
        case .activity: activityPanel
        case .modules: linkPanel
        case .protocolPanel: modePanel
        }
    }

    private var stateLabel: some View {
        let label = assistant.privacyMode ? "PRIVACY · ⌃⌥P PER RIATTIVARE"
            : (assistant.language == .italian ? assistant.state.label.it : assistant.state.label.en)
        return VStack(spacing: 4) {
            Text(label)
                .padding(.horizontal, 12).padding(.vertical, 3)
                .background(Capsule().fill(HUD.background.opacity(0.55)))
                .font(HUD.font(13, .bold)).tracking(5)
                .foregroundStyle(assistant.state.isError ? HUD.amber : HUD.ice)
                .shadow(color: HUD.cyan, radius: 6)
            if case .booting(let detail) = assistant.state {
                Text(detail.uppercased()).font(HUD.font(9)).tracking(2).foregroundStyle(HUD.cyan.opacity(0.8))
            }
            if case .error(let detail) = assistant.state {
                // The cause of the error, under the label: you know at once what is wrong.
                Text(detail).font(HUD.font(10)).foregroundStyle(HUD.amber.opacity(0.9))
                    .multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: 440)
            }
            if assistant.config.developerMode {
                Text("MODALITÀ TEST ATTIVA").font(HUD.font(9)).tracking(2).foregroundStyle(HUD.amber)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: label)
    }

    private var linkPanel: some View {
        HUDPanel(title: "MODULI") {
            VStack(alignment: .leading, spacing: 8) {
                HUDReadout(label: "WAKE WORD", value: assistant.wakeStatus)
                HUDReadout(label: "UDITO", value: assistant.sttStatus)
                HUDReadout(label: "NUCLEO", value: assistant.brainStatus)
                HUDReadout(label: "VOCE", value: assistant.voiceStatus)
                if assistant.printer.isConfigured {
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        HUDReadout(label: "STAMPANTE", value: assistant.printer.hudStatus)
                    }
                }
            }
        }
    }

    private var activityPanel: some View {
        HUDPanel(title: "ATTIVITÀ") {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    if let current = activity.current {
                        HUDReadout(label: current.category == .study ? "STUDIO IN CORSO" : "LAVORO IN CORSO",
                                   value: "\(current.name.uppercased()) · \(ActivityTracker.clock(current.duration))")
                    } else {
                        HUDReadout(label: "IN CORSO", value: "NESSUNA SESSIONE")
                    }
                    HStack {
                        HUDReadout(label: "OGGI", value: Self.hoursMinutes(activity.todayTotal))
                        Spacer()
                        HUDReadout(label: "SETTIMANA", value: Self.hoursMinutes(activity.weekTotal))
                    }
                }
            }
        }
    }

    private static func hoursMinutes(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return "\(minutes / 60)H \(String(format: "%02d", minutes % 60))M"
    }

    private var modePanel: some View {
        HUDPanel(title: "PROTOCOLLO") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([Language.italian, Language.english], id: \.rawValue) { lang in
                        Text(lang.label)
                            .font(HUD.font(13, .bold)).tracking(2)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .foregroundStyle(assistant.language == lang ? HUD.background : HUD.cyan)
                            .background(assistant.language == lang ? HUD.cyan : HUD.cyan.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(HUD.cyan.opacity(0.5), lineWidth: 1))
                    }
                }
                HUDReadout(label: "ATTIVAZIONE", value: "\"JARVIS\" · ⌃⌥SPAZIO")
                Text("CERVELLO").font(HUD.font(9)).tracking(2).foregroundStyle(HUD.cyan.opacity(0.6))
                HStack(spacing: 8) {
                    brainButton(.local, title: "LOCALE")
                    brainButton(.claude, title: "CLAUDE")
                }
                Text("MODELLO CLAUDE").font(HUD.font(9)).tracking(2).foregroundStyle(HUD.cyan.opacity(0.6))
                HStack(spacing: 6) {
                    ForEach(Assistant.claudeModels, id: \.self) { model in
                        let active = assistant.claudeModel == model
                        Button { assistant.setClaudeModel(model) } label: {
                            Text(model.uppercased())
                                .font(HUD.font(10, .bold)).tracking(1.5)
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                                .foregroundStyle(active ? HUD.background : HUD.cyan)
                                .background(active ? HUD.cyan.opacity(0.85) : HUD.cyan.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(HUD.cyan.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HUDReadout(label: "CLAUDE", value: assistant.online ? assistant.claudeStatus : "OFFLINE · RISPONDE GEMMA")
            }
        }
    }

    /// Lit: the chosen brain, or the one answering right now
    /// (if Claude answers instead of the local model, CLAUDE lights up, with a dot).
    private func brainButton(_ brain: Assistant.Brain, title: String) -> some View {
        let active = (assistant.answering ?? assistant.brain) == brain
        let standIn = assistant.answering == brain && assistant.brain != brain
        return Button { assistant.setBrain(brain) } label: {
            Text(standIn ? "● " + title : title)
                .font(HUD.font(12, .bold)).tracking(2)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(active ? HUD.background : HUD.cyan)
                .background(active ? HUD.cyan : HUD.cyan.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(HUD.cyan.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var logPanel: some View {
        HUDPanel(title: "REGISTRO") {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(assistant.log.suffix(60).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(HUD.mono(10)).foregroundStyle(HUD.cyan.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if assistant.log.isEmpty {
                        Text("Nessun evento").font(HUD.mono(10)).foregroundStyle(HUD.cyan.opacity(0.4))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Scrollable conversation history.
    /// It scrolls down by itself to the last message while JARVIS answers.
    private var transcriptPanel: some View {
        HUDPanel(title: "FRASI") {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if assistant.conversation.isEmpty {
                            transcriptLine(tag: "JARVIS", text: "—", color: HUD.ice)
                        }
                        ForEach(assistant.conversation) { exchange in
                            VStack(alignment: .leading, spacing: 4) {
                                if !exchange.user.isEmpty {
                                    transcriptLine(tag: "TU", text: exchange.user, color: HUD.cyan.opacity(0.85))
                                }
                                if !exchange.reply.isEmpty {
                                    transcriptLine(tag: "JARVIS", text: exchange.reply, color: HUD.ice)
                                }
                            }
                            .padding(.bottom, 4)
                            .overlay(alignment: .bottom) { Rectangle().fill(HUD.cyan.opacity(0.08)).frame(height: 1) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.trailing, 8)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: .infinity)
                .onChange(of: assistant.conversation.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: assistant.conversation.last?.reply) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func transcriptLine(tag: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(tag).font(HUD.font(9, .bold)).tracking(1.5).foregroundStyle(HUD.cyan.opacity(0.6))
                .frame(width: 44, alignment: .leading)
            Text(text)
                .font(HUD.font(13)).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: Components

/// Dark translucent halo around the reactor: it fades into the desktop, without borders,
/// so the window looks like an enlarged NUCLEUS.
struct NucleusHalo: View {
    var body: some View {
        RadialGradient(stops: [.init(color: HUD.background.opacity(0.62), location: 0),
                               .init(color: HUD.background.opacity(0.5), location: 0.72),
                               .init(color: .clear, location: 1)],
                       center: UnitPoint(x: 0.5, y: HUDView.reactorCenterFromTop / HUDView.size.height), startRadius: 0, endRadius: 268)
    }
}

/// Box with bracket corners and a header, in the style of holographic panels.
struct HUDPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Capsule().fill(HUD.cyan).frame(width: 3, height: 10)
                Text(title).font(HUD.font(11, .bold)).tracking(3).foregroundStyle(HUD.cyan)
                Rectangle().fill(HUD.cyan.opacity(0.25)).frame(height: 1)
            }
            content
        }
        .padding(14)
        .background(HUD.cyan.opacity(0.035), in: HUD.panelShape)
        .overlay(HUD.panelShape.stroke(HUD.cyan.opacity(0.35), lineWidth: 1))
    }
}

struct HUDReadout: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(HUD.font(9)).tracking(2).foregroundStyle(HUD.cyan.opacity(0.6))
            Text(value).font(HUD.font(12, .bold)).foregroundStyle(HUD.ice).lineLimit(2)
        }
    }
}

struct HUDIconButton: View {
    let symbol: String
    var active = false
    var shown = true
    var onHoverChange: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hover || active ? HUD.background : HUD.cyan)
                .frame(width: 32, height: 32)
                .background(hover || active ? HUD.cyan : HUD.background.opacity(0.7), in: shape)
                .overlay(shape.stroke(HUD.cyan.opacity(0.6), lineWidth: 1))
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: shown)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0; onHoverChange($0) }
    }
}
