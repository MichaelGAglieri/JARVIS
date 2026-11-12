import SwiftUI

/// JARVIS's panels: each opens in its own movable window from the menu bar ("Schede").
enum HUDDrawer: String, CaseIterable, Identifiable {
    case transcript, log, activity, modules, protocolPanel, thought
    var id: String { rawValue }
    /// Histories open on the left of JARVIS the first time, controls and state on the right.
    var isLeft: Bool { [.transcript, .log, .activity].contains(self) }
    var symbol: String {
        switch self {
        case .transcript: return "text.bubble"
        case .log: return "list.bullet.rectangle"
        case .activity: return "clock"
        case .modules: return "square.stack.3d.up"
        case .protocolPanel: return "slider.horizontal.3"
        case .thought: return "terminal"
        }
    }
    var title: String {
        switch self {
        case .transcript: return "Frasi"
        case .log: return "Registro"
        case .activity: return "Attività"
        case .modules: return "Moduli"
        case .protocolPanel: return "Protocollo"
        case .thought: return "Pensiero"
        }
    }
}

/// Main screen: only the reactor and its state, with no buttons around it. Panels, SATELLITE
/// and settings are in the menu bar (JARVIS icon, and "Schede" on the left); Esc hides it.
/// A double click on the sphere goes back to the SATELLITE.
struct HUDView: View {
    /// The window wraps the sphere closely (11 November): the drawn sphere is about 400 points
    /// across inside its 490-point frame, and up to 7% larger while JARVIS speaks.
    static let size = CGSize(width: 440, height: 472)
    static let reactorSize: CGFloat = 490
    /// The sphere's centre, from the top of the window; the state label sits under it.
    static let reactorCenterFromTop: CGFloat = 220

    @ObservedObject var assistant: Assistant
    var onCompact: () -> Void = {}
    /// Reactor drag in progress; `true` when it ends.
    var onWindowDrag: (Bool) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NucleusHalo()
                .frame(width: Self.size.width, height: Self.size.height)
            ReactorView(assistant: assistant, paused: !assistant.hudVisible)
                .frame(width: Self.reactorSize, height: Self.reactorSize)
                .position(x: Self.size.width / 2, y: Self.reactorCenterFromTop)
            stateLabel
                .position(x: Self.size.width / 2, y: Self.size.height - 26)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // The window moves by dragging the sphere; a double click reduces it to the SATELLITE.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onCompact() }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in onWindowDrag(false) }
            .onEnded { _ in onWindowDrag(true) })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private var stateLabel: some View {
        let label = assistant.privacyMode ? "PRIVACY · ⌃⌥P PER RIATTIVARE"
            : (assistant.language == .italian ? assistant.state.label.it : assistant.state.label.en)
        // The everyday states (waiting, working, answering) are not written: the sphere shows them
        // (11 November, user request). Only what needs the user's attention stays: privacy and errors.
        let shown = assistant.privacyMode || assistant.state.isError
        return VStack(spacing: 4) {
            if shown {
                Text(label)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .background(Capsule().fill(HUD.background.opacity(0.55)))
                    .font(HUD.font(13, .bold)).tracking(5)
                    .foregroundStyle(assistant.state.isError ? HUD.amber : HUD.ice)
                    .shadow(color: HUD.cyan, radius: 6)
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

}

/// What one panel shows. Since 1.30.17 each panel is its own movable window,
/// opened from the menu bar ("Schede"), in both neural-orb and SATELLITE modes.
struct HUDDrawerContent: View {
    let drawer: HUDDrawer
    @ObservedObject var assistant: Assistant
    @ObservedObject var activity: ActivityTracker

    var body: some View {
        switch drawer {
        case .transcript: transcriptPanel
        case .log: logPanel
        case .activity: activityPanel
        case .modules: linkPanel
        case .protocolPanel: modePanel
        case .thought: thoughtPanel
        }
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

    /// A terminal of JARVIS's observable activity: route chosen, tools run, searches, files, sources, timings.
    private var thoughtPanel: some View {
        HUDPanel(title: "PENSIERO") {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if assistant.thoughts.isEmpty {
                            Text("> in attesa di una richiesta_").font(HUD.mono(10)).foregroundStyle(HUD.cyan.opacity(0.4))
                        }
                        ForEach(assistant.thoughts) { line in
                            Text("\(line.time) \(line.message)").font(HUD.mono(10))
                                .foregroundStyle(Self.thoughtColor(line.message))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        if [.thinking, .acting].contains(assistant.state) {
                            Text("▌").font(HUD.mono(10)).foregroundStyle(HUD.ice)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(8)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxHeight: .infinity)
                .onChange(of: assistant.thoughts.last?.id) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private static func thoughtColor(_ body: String) -> Color {
        if body.hasPrefix("✕") { return HUD.amber }
        if body.hasPrefix("»") { return HUD.ice }
        if body.hasPrefix("←") { return HUD.cyan.opacity(0.55) }
        if body.hasPrefix("✓") { return Color.green.opacity(0.8) }
        return HUD.cyan.opacity(0.9)
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
                       center: UnitPoint(x: 0.5, y: HUDView.reactorCenterFromTop / HUDView.size.height), startRadius: 0, endRadius: 225)
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
