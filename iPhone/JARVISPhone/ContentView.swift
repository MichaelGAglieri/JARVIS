import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var assistant: Assistant
    @State private var draft = ""
    @State private var showPairing = false
    @State private var isWide = false
    @State private var barOpen = false
    @State private var showLastWords = true
    @State private var pressing = false
    /// Off at every opening: a tap to zoom must not click on the Mac.
    @State private var controlling = false
    @State private var macDraft = ""
    @FocusState private var typing: Bool

    private func font(_ size: CGFloat) -> Font { .custom("DIN Alternate", size: size) }

    var body: some View {
        ZStack {
            HUD.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if assistant.isPaired {
                    conversationArea
                    if assistant.link == .elsewhere {
                        Button("Usa qui") { assistant.takeOver() }
                            .font(font(20))
                            .buttonStyle(.borderedProminent)
                            .tint(HUD.deep)
                            .frame(height: 56)
                    } else {
                        inputBar
                            .frame(maxWidth: 720)
                    }
                } else {
                    Spacer()
                    Button("Abbina al Mac") { showPairing = true }
                        .font(font(20))
                        .buttonStyle(.borderedProminent)
                        .tint(HUD.deep)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
        }
        .fullScreenCover(isPresented: Binding(get: { assistant.watching && !assistant.locked },
                                              set: { if !$0 { assistant.stopWatching() } })) {
            screenView
        }
        .overlay {
            if assistant.locked { lockScreen }
        }
        .onChange(of: assistant.watching) { _, now in
            // When the view ends, go back to portrait, the only way the rest of the app fits.
            if now {
                AppOrientation.set(allowed: .allButUpsideDown)
            } else {
                barOpen = false
                typing = false
                AppOrientation.set(allowed: .portrait, go: .portrait)
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingView(assistant: assistant)
        }
        .onAppear {
            if !assistant.isPaired { showPairing = true }
        }
    }

    /// The Mac screen. In portrait the controls sit above and below; in landscape they sit in a column
    /// on the side, so the image takes all the rest, and the typing bar appears only when needed.
    private var screenView: some View {
        GeometryReader { space in
            let wide = space.size.width > space.size.height
            ZStack {
                HUD.background.ignoresSafeArea()
                if wide { wideScreenView } else { tallScreenView }
            }
            .frame(width: space.size.width, height: space.size.height)
            .onAppear { isWide = wide }
            .onChange(of: wide) { _, now in isWide = now }
        }
    }

    private var tallScreenView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                closeButton
                Text(assistant.isConnected ? assistant.state.label.it : "CERCO IL MAC")
                    .font(font(14))
                    .tracking(2)
                    .foregroundStyle(HUD.cyan)
                    .lineLimit(1)
                Spacer()
                controlButton
                if !AppOrientation.isPad { rotateButton }
                stopButton
            }
            .font(.system(size: 18))
            .foregroundStyle(HUD.cyan)
            macScreen
            if !lastWords.isEmpty {
                ScrollView {
                    Text(lastWords)
                        .font(.subheadline)
                        .foregroundStyle(HUD.ice)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            if controlling { keyboardBar } else { inputBar }
        }
        .padding(.horizontal, 12)
    }

    private var wideScreenView: some View {
        HStack(spacing: 8) {
            macScreen
                .overlay(alignment: .bottom) {
                    if showLastWords, !lastWords.isEmpty, !barOpen {
                        Text(lastWords)
                            .font(.footnote)
                            .foregroundStyle(HUD.ice)
                            .lineLimit(3)
                            .padding(8)
                            .background(HUD.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .task(id: lastWords) {
                    showLastWords = true
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { showLastWords = false }
                }
            if barOpen {
                // The keyboard takes the lower half: the bar sits beside it and the image stays as large as possible.
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        closeButton
                        controlButton
                        stopButton
                        Spacer(minLength: 0)
                        Button {
                            barOpen = false
                            typing = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Chiudi la tastiera")
                    }
                    .font(.system(size: 18))
                    .foregroundStyle(HUD.cyan)
                    if controlling { keyboardBar } else { inputBar }
                    Spacer(minLength: 0)
                }
                .frame(width: 370)
            } else {
                VStack(spacing: 2) {
                    closeButton
                    controlButton
                    if !AppOrientation.isPad { rotateButton }
                    stopButton
                    Button {
                        barOpen = true
                        typing = true
                    } label: {
                        Image(systemName: "keyboard").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Tastiera")
                    Spacer(minLength: 0)
                    talkButton
                        .disabled(!assistant.isConnected)
                        .opacity(assistant.isConnected ? 1 : 0.45)
                }
                .font(.system(size: 18))
                .foregroundStyle(HUD.cyan)
                .frame(width: 58)
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }

    private var lastWords: String { assistant.notice.isEmpty ? assistant.reply : assistant.notice }

    @ViewBuilder private var macScreen: some View {
        if let image = assistant.screen {
            ZoomableImage(image: image, sink: assistant.screenSink, controlling: controlling) { kind, x, y, amount in
                assistant.pointer(kind, x: x, y: y, amount: amount)
            }
        } else {
            ZStack {
                Color.clear
                ProgressView().tint(HUD.cyan)
            }
        }
    }

    private var closeButton: some View {
        Button { assistant.stopWatching() } label: {
            Image(systemName: "xmark").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Chiudi")
    }

    private var controlButton: some View {
        Button { controlling.toggle() } label: {
            Image(systemName: controlling ? "cursorarrow.click.2" : "cursorarrow")
                .frame(width: 44, height: 44)
                .background(controlling ? HUD.cyan.opacity(0.25) : .clear, in: Circle())
        }
        .accessibilityLabel(controlling ? "Controllo del Mac attivo" : "Attiva il controllo del Mac")
    }

    /// Rotates the whole view, keyboard included, even with rotation lock on.
    private var rotateButton: some View {
        Button {
            typing = false
            barOpen = false
            AppOrientation.set(allowed: .allButUpsideDown, go: isWide ? .portrait : .landscapeRight)
        } label: {
            Image(systemName: isWide ? "iphone" : "iphone.landscape").frame(width: 44, height: 44)
        }
        .accessibilityLabel(isWide ? "Metti in verticale" : "Metti in orizzontale")
    }

    private var stopButton: some View {
        Button { assistant.stop() } label: {
            Image(systemName: "stop.fill").frame(width: 44, height: 44)
        }
        .disabled(!assistant.isBusy)
        .accessibilityLabel("Ferma JARVIS")
    }

    /// With control active you type on the Mac, not to JARVIS.
    private var keyboardBar: some View {
        HStack(spacing: 8) {
            TextField("Scrivi sul Mac", text: $macDraft)
                .focused($typing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit {
                    assistant.typeOnMac(macDraft)
                    macDraft = ""
                    // The keyboard stays open: often Return is pressed afterwards or more is typed.
                    typing = true
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(HUD.panelShape.fill(HUD.deep.opacity(0.18)))
                .overlay(HUD.panelShape.stroke(HUD.cyan.opacity(0.35), lineWidth: 1))
            ForEach([("return", "return", "Invio"), ("delete", "delete.left", "Cancella"), ("escape", "escape", "Esc")], id: \.0) { key in
                Button { assistant.pressOnMac(key.0) } label: {
                    Image(systemName: key.1)
                        .font(.system(size: 17))
                        .foregroundStyle(HUD.cyan)
                        .frame(width: 42, height: 44)
                        .background(HUD.panelShape.fill(HUD.deep.opacity(0.25)))
                }
                .accessibilityLabel(key.2)
            }
        }
        .padding(.vertical, 10)
        .disabled(!assistant.isConnected)
        .opacity(assistant.isConnected ? 1 : 0.45)
    }

    private var lockScreen: some View {
        ZStack {
            HUD.background.ignoresSafeArea()
            Button { assistant.unlock() } label: {
                VStack(spacing: 14) {
                    Image(systemName: "faceid").font(.system(size: 54))
                    Text("Sblocca JARVIS").font(font(20))
                }
                .foregroundStyle(HUD.cyan)
                .frame(minWidth: 200, minHeight: 140)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(linkColor).frame(width: 8, height: 8)
            Text(linkText)
                .font(font(13))
                .tracking(1.5)
                .foregroundStyle(HUD.ice.opacity(0.8))
                .lineLimit(1)
            Spacer()
            if assistant.isConnected {
                Button {
                    assistant.startWatching()
                } label: {
                    Image(systemName: "display")
                        .font(.system(size: 18))
                        .foregroundStyle(HUD.cyan)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Guarda lo schermo del Mac")
            }
            Button {
                showPairing = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(HUD.cyan)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Abbinamento")
        }
    }

    private var linkText: String {
        switch assistant.link {
        case .unpaired: return "NON ABBINATO"
        case .searching: return "CERCO IL MAC"
        case .connected(let name): return name.uppercased()
        case .refused: return "CODICE NON VALIDO"
        case .elsewhere: return "IN USO ALTROVE"
        }
    }

    private var linkColor: Color {
        switch assistant.link {
        case .connected: return HUD.cyan
        case .refused: return HUD.amber
        default: return HUD.privacy
        }
    }

    /// The reactor sits at the centre of the app, with its state below; words fill the space left at the bottom.
    private var conversationArea: some View {
        GeometryReader { space in
            let side = typing ? min(space.size.width * 0.4, 130) : min(space.size.width * 0.9, space.size.height * 0.52, AppOrientation.isPad ? 560 : 350)
            let center = typing ? side / 2 + 6 : space.size.height / 2
            let textTop = center + side / 2 + 34
            ZStack(alignment: .top) {
                ReactorView(assistant: assistant)
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
                    .onTapGesture { if assistant.isBusy || assistant.talking { assistant.stop() } }
                    .accessibilityLabel("Reattore: tocca per fermare JARVIS")
                    .position(x: space.size.width / 2, y: center)
                Text(assistant.link == .elsewhere ? "IN PAUSA" : assistant.earOn ? "DI' JARVIS" : assistant.state.label.it)
                    .font(font(15))
                    .tracking(3)
                    .foregroundStyle(assistant.state.isError ? HUD.amber : HUD.cyan)
                    .position(x: space.size.width / 2, y: center + side / 2 + 14)
                transcript
                    .frame(height: max(space.size.height - textTop, 0))
                    .offset(y: textTop)
            }
            .animation(.easeInOut(duration: 0.2), value: typing)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .center, spacing: 8) {
                    if !assistant.heard.isEmpty {
                        Text(assistant.heard)
                            .font(.subheadline)
                            .foregroundStyle(HUD.ice.opacity(0.65))
                    }
                    if !assistant.reply.isEmpty {
                        Text(assistant.reply)
                            .font(.body)
                            .foregroundStyle(HUD.ice)
                            .textSelection(.enabled)
                    }
                    if !assistant.expiryNotice.isEmpty {
                        Text(assistant.expiryNotice)
                            .font(.subheadline)
                            .foregroundStyle(HUD.amber)
                    }
                    if !assistant.notice.isEmpty {
                        Text(assistant.notice)
                            .font(.subheadline)
                            .foregroundStyle(HUD.amber)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: assistant.reply) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: assistant.notice) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Scrivi a JARVIS", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .submitLabel(.send)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(HUD.panelShape.fill(HUD.deep.opacity(0.18)))
                .overlay(HUD.panelShape.stroke(HUD.cyan.opacity(0.35), lineWidth: 1))
                .onChange(of: draft) { _, new in
                    // In a multi-line field Return arrives as a newline.
                    if new.hasSuffix("\n") { sendDraft() }
                }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                talkButton
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(HUD.background)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(HUD.cyan))
                }
                .accessibilityLabel("Invia")
            }
        }
        .padding(.vertical, 10)
        .disabled(!assistant.isConnected)
        .opacity(assistant.isConnected ? 1 : 0.45)
    }

    /// Tap and speak, it stops by itself when you stop. Holding, it stops on release.
    private var talkButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 24))
            .foregroundStyle(assistant.talking ? HUD.background : HUD.cyan)
            .frame(width: 56, height: 56)
            .background(Circle().fill(assistant.talking ? HUD.cyan : HUD.deep.opacity(0.25)))
            .overlay(Circle().stroke(HUD.cyan.opacity(0.6), lineWidth: 1))
            .scaleEffect(assistant.talking ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: assistant.talking)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        assistant.micPressed()
                    }
                    .onEnded { _ in
                        pressing = false
                        assistant.micReleased()
                    }
            )
            .accessibilityLabel("Tocca per parlare")
    }

    private func sendDraft() {
        assistant.send(text: draft)
        draft = ""
        typing = false
    }
}

/// When the phone rotates, the image that is not zoomed adapts to the new space.
private final class FittingScrollView: UIScrollView {
    private let content: UIView

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale <= 1.001 else { return }
        content.frame = bounds
        contentSize = bounds.size
    }
}

/// The Mac screen: two fingers zoom and, with control active, a tap is a click, two
/// taps a double click, a long press a right click and a sliding finger scrolls the window.
/// The Mac screen view: the image gives size and first frame, the video above it
/// is shown by the system like a movie, without copying the frames.
final class ScreenImageView: UIImageView {
    let videoLayer = AVSampleBufferDisplayLayer()

    init() {
        super.init(frame: .zero)
        videoLayer.videoGravity = .resizeAspect
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Brings the Mac screen frames straight into the view that shows them.
/// Keeps the frames since the last keyframe: if the view is created later, it receives them all.
@MainActor
final class ScreenSink {
    weak var view: ScreenImageView? {
        didSet { replay() }
    }
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var group: [CMSampleBuffer] = []

    var hasVideo: Bool { format != nil }

    func reset() {
        format = nil
        parameterSets = []
        group = []
        view?.videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Photos (older Mac): false if the view does not exist yet, and then it goes through SwiftUI.
    func show(_ image: UIImage) -> Bool {
        guard let view, view.image?.size == image.size else { return false }
        view.image = image
        return true
    }

    /// False if the frame cannot be used (the keyframe is missing).
    func receive(_ packet: VideoPacket) -> Bool {
        if packet.keyframe, !packet.parameterSets.isEmpty, packet.parameterSets != parameterSets {
            guard let made = Self.format(packet.parameterSets) else { return false }
            format = made
            parameterSets = packet.parameterSets
            view?.videoLayer.sampleBufferRenderer.flush()
        }
        guard let format, let sample = Self.sample(packet.data, format: format) else { return false }
        if packet.keyframe { group = [] }
        if group.count < 900 { group.append(sample) }
        if let layer = view?.videoLayer { enqueue(sample, on: layer) }
        return true
    }

    private func replay() {
        guard let layer = view?.videoLayer, !group.isEmpty else { return }
        layer.sampleBufferRenderer.flush()
        group.forEach { enqueue($0, on: layer) }
    }

    private func enqueue(_ sample: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            // After an error a keyframe is needed: start again from the last one.
            group.forEach { renderer.enqueue($0) }
            return
        }
        renderer.enqueue(sample)
    }

    private static func format(_ sets: [Data]) -> CMVideoFormatDescription? {
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
                                                                    parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }

    private static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // No clock: each frame is shown as soon as it is decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// Later frames arrive here directly, without redrawing the whole view.
    let sink: ScreenSink
    let controlling: Bool
    let onPointer: (_ kind: String, _ x: Double, _ y: Double, _ amount: Int?) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let coordinator = context.coordinator
        let scroll = FittingScrollView(content: coordinator.view)
        scroll.maximumZoomScale = 6
        scroll.delegate = coordinator
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        coordinator.scroll = scroll
        let view = coordinator.view
        sink.view = view
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(view)
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        let long = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.longPress(_:)))
        scroll.addGestureRecognizer(long)
        // Like a trackpad: one finger drags (windows, text), two fingers scroll, pinch zooms.
        let drag = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.drag(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = coordinator
        scroll.addGestureRecognizer(drag)
        coordinator.dragGesture = drag
        let twoFingers = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        twoFingers.minimumNumberOfTouches = 2
        twoFingers.maximumNumberOfTouches = 2
        twoFingers.delegate = coordinator
        scroll.addGestureRecognizer(twoFingers)
        coordinator.scrollGesture = twoFingers
        // With the photo zoomed in, one finger moves it: two fingers stay for scrolling the Mac.
        scroll.panGestureRecognizer.maximumNumberOfTouches = 1
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        // Only the first image (or a size change) passes here: `sink` puts in the others.
        if coordinator.view.image == nil || coordinator.view.image?.size != image.size { coordinator.view.image = image }
        coordinator.controlling = controlling
        coordinator.onPointer = onPointer
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let view = ScreenImageView()
        weak var scroll: UIScrollView?
        var controlling = false
        var onPointer: ((String, Double, Double, Int?) -> Void)?
        private var lastScroll = Date.distantPast
        private var pending: CGFloat = 0
        weak var dragGesture: UIGestureRecognizer?
        weak var scrollGesture: UIGestureRecognizer?
        private var dragStart: (x: Double, y: Double)?
        private var dragging = false
        private var lastDrag = Date.distantPast
        private var zoomAtScrollStart: CGFloat = 1

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view }

        /// From the touched point to the position on the original photo, accounting for empty borders and rotation.
        /// `clamped`: during a drag the finger can leave the image, the pointer stays at the edge.
        private func position(of gesture: UIGestureRecognizer, clamped: Bool = false) -> (x: Double, y: Double)? {
            guard let image = view.image, image.size.width > 0, image.size.height > 0 else { return nil }
            let box = view.bounds.size
            let scale = min(box.width / image.size.width, box.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2)
            let point = gesture.location(in: view)
            var u = Double((point.x - origin.x) / size.width)
            var v = Double((point.y - origin.y) / size.height)
            if clamped {
                u = min(max(u, 0), 1)
                v = min(max(v, 0), 1)
            }
            guard (0...1).contains(u), (0...1).contains(v) else { return nil }
            return (u, v)
        }

        @objc func singleTap(_ gesture: UITapGestureRecognizer) {
            guard controlling, let at = position(of: gesture) else { return }
            onPointer?("click", at.x, at.y, nil)
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            if controlling {
                if let at = position(of: gesture) { onPointer?("double", at.x, at.y, nil) }
                return
            }
            guard let scroll else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: view)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }

        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            guard controlling, gesture.state == .began, let at = position(of: gesture) else { return }
            onPointer?("right", at.x, at.y, nil)
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard controlling else { return false }
            // With the photo zoomed in, one finger moves the photo, not the window on the Mac.
            if gesture === dragGesture { return (scroll?.zoomScale ?? 1) <= 1.01 }
            return true
        }

        /// Two fingers: they scroll and meanwhile the pinch can zoom.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gesture === scrollGesture && other === scroll?.pinchGestureRecognizer
        }

        /// One finger: press, drag, release. This is how windows are moved by their title bar.
        @objc func drag(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                // The point where the finger landed, not where it has already got to.
                guard let at = position(of: gesture) else { return }
                let move = gesture.translation(in: view)
                let box = view.bounds.size
                let start = (x: at.x - Double(move.x / max(box.width, 1)), y: at.y - Double(move.y / max(box.height, 1)))
                dragStart = (min(max(start.x, 0), 1), min(max(start.y, 0), 1))
                dragging = true
                onPointer?("down", dragStart!.x, dragStart!.y, nil)
                if let at = position(of: gesture, clamped: true) { onPointer?("drag", at.x, at.y, nil) }
            case .changed:
                guard dragging, Date().timeIntervalSince(lastDrag) > 0.033, let at = position(of: gesture, clamped: true) else { return }
                lastDrag = Date()
                onPointer?("drag", at.x, at.y, nil)
            default:
                guard dragging else { return }
                dragging = false
                let at = position(of: gesture, clamped: true) ?? dragStart ?? (0.5, 0.5)
                onPointer?("up", at.x, at.y, nil)
                dragStart = nil
            }
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { zoomAtScrollStart = scroll?.zoomScale ?? 1 }
            // If the two fingers are zooming, it is not a scroll.
            if abs((scroll?.zoomScale ?? 1) - zoomAtScrollStart) > 0.05 * zoomAtScrollStart { return }
            guard let at = position(of: gesture, clamped: true) else { return }
            let move = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            pending += move.y
            guard Date().timeIntervalSince(lastScroll) > 0.08 || gesture.state == .ended else { return }
            lastScroll = Date()
            onPointer?("scroll", at.x, at.y, Int(pending * 3))
            pending = 0
        }
    }
}
