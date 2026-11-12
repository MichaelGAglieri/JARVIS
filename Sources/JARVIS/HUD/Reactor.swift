import SwiftUI
import MetalKit
import simd

enum HUD {
    static let cyan = Color(red: 0.31, green: 0.86, blue: 1.0)
    static let ice = Color(red: 0.80, green: 0.97, blue: 1.0)
    static let deep = Color(red: 0.02, green: 0.45, blue: 0.80)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let privacy = Color(red: 0.55, green: 0.60, blue: 0.66)
    static let background = Color(red: 0.01, green: 0.04, blue: 0.08)
    /// Panels and drop-downs have soft corners, like everything else.
    static let panelShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("DIN Alternate", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

/// Animation state kept from one frame to the next.
/// Rotation is accumulated (not computed from absolute time) so when
/// speed changes the rings accelerate smoothly, without jumps.
final class ReactorAnimator {
    private var last: Date?
    private let start = Date()
    private(set) var phase: Double = 0
    private(set) var time: Double = 0
    private(set) var speed: Double = 0.3
    private(set) var energy: Double = 0.4
    private(set) var level: Double = 0
    private(set) var boot: Double = 0
    private(set) var alert: Double = 0
    private(set) var privacy: Double = 0

    struct Particle { let radius: Double; let angle: Double; let speed: Double; let size: Double; let twinkle: Double }
    let particles: [Particle] = (0..<56).map { i in
        var g = SeededRandom(seed: UInt64(i + 1) * 7919)
        return Particle(radius: 0.30 + g.next() * 0.66, angle: g.next() * .pi * 2,
                        speed: (g.next() - 0.5) * 0.5, size: 0.8 + g.next() * 1.8, twinkle: g.next() * 10)
    }

    func step(_ now: Date, state: Assistant.State, deepIdle: Bool, privacy privacyMode: Bool = false, mic: Float, voice: Float) {
        let dt = min(1.0 / 20, last.map { now.timeIntervalSince($0) } ?? 0)
        last = now
        time = now.timeIntervalSince(start)
        boot = min(1, time / 2.2)

        let (targetSpeed, targetEnergy, raw): (Double, Double, Double) = {
            switch state {
            case .booting: return (1.4, 0.7, 0.15 + 0.15 * sin(time * 6))
            // After a minute of waiting almost still: at 6 frames per second a
            // visible rotation would look jerky, an almost still one does not.
            case .idle: return (deepIdle ? 0.025 : 0.22, deepIdle ? 0.4 : 0.45, Double(mic) * 0.35)
            case .listening: return (0.65, 0.95, Double(mic))
            case .transcribing: return (1.5, 1.0, 0.25)
            case .thinking: return (2.1, 1.0, 0.3 + 0.2 * sin(time * 9))
            case .acting: return (1.8, 1.0, 0.45 + 0.25 * sin(time * 14))
            case .speaking: return (0.8, 0.95, Double(voice))
            case .error: return (0.12, 0.6, 0.05)
            }
        }()
        let k = 1 - exp(-dt * 4)
        speed += (targetSpeed - speed) * k
        energy += (targetEnergy - energy) * k
        // The level rises at once and falls slowly, like a VU meter.
        level += (raw - level) * (raw > level ? 1 - exp(-dt * 30) : 1 - exp(-dt * 6))
        alert += ((state.isError ? 1 : 0) - alert) * k
        privacy += ((privacyMode ? 1 : 0) - privacy) * k
        phase += dt * speed
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

extension Assistant.State {
    var isError: Bool { if case .error = self { return true } else { return false } }
}

/// The public entry point is shared by the full HUD and the desktop NUCLEUS.
/// TimelineView is the only clock: Metal never starts its own display link.
struct ReactorView: View {
    @ObservedObject var assistant: Assistant
    var compact = false
    var paused = false
    @State private var animator = ReactorAnimator()
    @State private var motion = SphereMotion()

    var body: some View {
        Group {
            if compact {
                // The NUCLEUS widget on the desktop stays the original reactor.
                ClassicReactorView(assistant: assistant, paused: paused)
            } else if let resources = SphereGPU.shared {
                TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { timeline in
                    SphereSurface(resources: resources, animator: animator, motion: motion, date: timeline.date,
                                  state: assistant.state, deepIdle: assistant.deepIdle,
                                  privacy: assistant.privacyMode, mic: assistant.levels.mic,
                                  voice: assistant.levels.voice, compact: compact, paused: paused)
                }
            } else {
                // A failed Metal setup must not make the NUCLEUS disappear.
                // Static, cached geometry; no alternative animation loop or blur.
                Canvas { context, size in
                    let radius = min(size.width, size.height) * 0.46
                    context.translateBy(x: size.width / 2, y: size.height / 2)
                    context.scaleBy(x: radius, y: radius)
                    let color = assistant.privacyMode ? HUD.privacy : assistant.state.isError ? HUD.amber : HUD.cyan
                    context.stroke(SphereGeometry.fallback, with: .color(color.opacity(0.6)), lineWidth: 1 / radius)
                }
            }
        }
        .allowsHitTesting(false) // The existing HUD/NUCLEUS retains clicks, hover and drag.
        .accessibilityHidden(true)
    }

    /// The sphere keeps moving while waiting: 20 fps (it costs about 1 ms of GPU per
    /// frame), 6 after a minute of waiting, 30 while JARVIS works.
    private var frameInterval: Double {
        guard assistant.state == .idle else { return 1.0 / 30 }
        return assistant.deepIdle ? 1.0 / 6 : 1.0 / 20
    }
}

// The same sphere on the Mac and in the iPhone/iPad app, which shares this file.
#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

private struct SphereSurface: PlatformViewRepresentable {
    let resources: SphereGPU
    let animator: ReactorAnimator
    let motion: SphereMotion
    let date: Date
    let state: Assistant.State
    let deepIdle: Bool
    let privacy: Bool
    let mic: Float
    let voice: Float
    let compact: Bool
    let paused: Bool

    #if os(macOS)
    func makeNSView(context: Context) -> SphereMetalView { SphereMetalView(resources: resources) }
    func updateNSView(_ view: SphereMetalView, context: Context) { update(view) }
    static func dismantleNSView(_ view: SphereMetalView, coordinator: ()) { dismantle(view) }
    #else
    func makeUIView(context: Context) -> SphereMetalView { SphereMetalView(resources: resources) }
    func updateUIView(_ view: SphereMetalView, context: Context) { update(view) }
    static func dismantleUIView(_ view: SphereMetalView, coordinator: ()) { dismantle(view) }
    #endif

    private func update(_ view: SphereMetalView) {
        view.frozen = paused
        guard !paused else { return }
        animator.step(date, state: state, deepIdle: deepIdle, privacy: privacy, mic: mic, voice: voice)
        // SwiftUI also calls this when the audio levels publish, with the same timeline
        // date: nothing has moved, so no extra frame is drawn.
        guard motion.step(date, state: state, deepIdle: deepIdle, animator: animator) else { return }
        view.uniforms = SphereUniforms(animator: animator, state: state, compact: compact, motion: motion)
        view.compact = compact
        view.renderFrame()
    }

    private static func dismantle(_ view: SphereMetalView) {
        view.frozen = true
        view.releaseDrawables()
    }
}

private final class SphereMetalView: MTKView {
    let resources: SphereGPU
    var uniforms = SphereUniforms()
    var compact = false
    var frozen = true
    // Two frames may be in flight: with one only, a GPU busy with speech synthesis
    // made every other frame drop and the motion stutter. A third is still dropped.
    private let availableFrame = DispatchSemaphore(value: 2)

    init(resources: SphereGPU) {
        self.resources = resources
        super.init(frame: .zero, device: resources.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        sampleCount = 1
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = false
        #if os(macOS)
        wantsLayer = true
        layer?.isOpaque = false
        #else
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.isOpaque = false
        #endif
        (layer as? CAMetalLayer)?.maximumDrawableCount = 3
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if os(macOS)
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        renderFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderFrame()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderFrame()
    }

    private var onScreen: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }
    private var pixelScale: CGFloat { window?.backingScaleFactor ?? 2 }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        renderFrame()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        renderFrame()
    }

    private var onScreen: Bool { window != nil && !isHidden && alpha > 0 }
    private var pixelScale: CGFloat { traitCollection.displayScale }
    #endif

    func renderFrame() {
        guard !frozen, onScreen,
              bounds.width > 0, bounds.height > 0, let metal = layer as? CAMetalLayer else { return }
        // Retina is capped at 2x. No full-screen offscreen textures or bloom passes.
        let scale = min(pixelScale, 2)
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        if metal.drawableSize != size { metal.drawableSize = size }
        guard availableFrame.wait(timeout: .now()) == .success else { return }
        // A fresh drawable for every frame, taken from the layer. MTKView's
        // currentDrawable is renewed only inside its own draw cycle, which this view
        // does not use: reusing it showed a single frame and then updated only
        // sporadically, which made the sphere stutter in every state.
        guard let drawable = metal.nextDrawable(), let command = resources.queue.makeCommandBuffer() else {
            availableFrame.signal()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        var values = uniforms
        values.viewport = SIMD4(Float(size.width), Float(size.height), Float(scale), 0)
        resources.encode(command: command, pass: pass, uniforms: values, compact: compact)
        let gate = availableFrame
        command.addCompletedHandler { _ in gate.signal() }
        #if SPHERE_HARNESS
        drawable.addPresentedHandler { d in SphereHarness.presented(d.presentedTime) }
        #endif
        command.present(drawable)
        command.commit()
    }
}

/// Smoothed values for the sphere. Every quantity that depends on the state eases
/// towards its new value, so passing from listening to thinking to speaking never
/// makes pulses jump, reverse abruptly or the sphere snap in size.
final class SphereMotion {
    private var last: Date?
    /// Position of the pulses along the paths, wrapped to 0...1.
    private(set) var flow: Double = 0.5
    /// +1 pulses run inwards (listening), -1 outwards; changes direction gradually.
    private(set) var direction: Double = -1
    /// 0 one pulse per path, 1 three (thinking, acting).
    private(set) var density: Double = 0
    /// Audio level, low-passed: the raw VU level jumps every frame with the voice.
    private(set) var level: Double = 0
    /// Extra scale from the voice.
    private(set) var swell: Double = 0
    /// Rotation of the sphere. While waiting it turns faster than the HUD's own
    /// animator would (still slow after a minute, when the frame rate drops to 6 fps).
    private(set) var spin: Double = 0
    private var idleBoost: Double = 0
    /// Clock of the neurons firing, wrapped at 400 (a multiple of every firing period).
    private(set) var fire: Double = 0

    /// Returns false when the date has not advanced: nothing new to draw.
    func step(_ now: Date, state: Assistant.State, deepIdle: Bool = false, animator a: ReactorAnimator) -> Bool {
        if let last, now <= last { return false }
        let dt = min(0.1, last.map { now.timeIntervalSince($0) } ?? 0)
        last = now
        let ease = 1 - exp(-dt * 3)
        idleBoost += ((state == .idle && !deepIdle ? 0.5 : 0) - idleBoost) * ease
        spin += dt * (a.speed + idleBoost)
        fire = (fire + dt * (0.45 + a.speed * 0.5 + idleBoost * 0.3)).truncatingRemainder(dividingBy: 400)
        direction += ((state == .listening ? 1 : -1) - direction) * ease
        density += ((state == .thinking || state == .acting ? 1 : 0) - density) * ease
        level += (a.level - level) * (1 - exp(-dt * 12))
        swell += (level * (state == .speaking ? 0.065 : 0.025) - swell) * (1 - exp(-dt * 10))
        flow = (flow + dt * a.speed * 0.24 * direction).truncatingRemainder(dividingBy: 1)
        if flow < 0 { flow += 1 }
        return true
    }
}

/// All fields are float4, with identical 16-byte alignment in Swift and Metal.
/// Only this small value is uploaded per frame; geometry never changes.
private struct SphereUniforms {
    var motion = SIMD4<Float>(0, 0, 0.4, 0) // time, phase, energy, level
    var state = SIMD4<Float>(1, 0, 0, 0) // boot, alert, privacy, flow phase
    var rotation = SIMD4<Float>(1, 0, 1, 0) // cos/sin yaw, cos/sin tilt
    var viewport = SIMD4<Float>(980, 980, 2, 0)
    var primary = SIMD4<Float>(0, 0, 0, 1)
    var ice = SIMD4<Float>(0, 0, 0, 1)
    var deep = SIMD4<Float>(0, 0, 0, 1)
    var dynamics = SIMD4<Float>(1, 1, 0, 0) // scale, speed, firing clock, pulse density

    init() {}

    init(animator a: ReactorAnimator, state assistantState: Assistant.State, compact: Bool, motion m: SphereMotion? = nil) {
        let level = m?.level ?? a.level
        let flow = m?.flow ?? (-a.phase * 0.24).truncatingRemainder(dividingBy: 1) + 1
        let spin = m?.spin ?? a.phase
        motion = SIMD4(Float(a.time), Float(spin), Float(a.energy), Float(level))
        state = SIMD4(Float(a.boot), Float(a.alert), Float(a.privacy), Float(flow))
        let yaw = Float(spin * 0.14)
        let tilt = Float(0.24 + sin(spin * 0.09) * 0.18)
        rotation = SIMD4(cos(yaw), sin(yaw), cos(tilt), sin(tilt))
        let muted = Float(1 - a.privacy * 0.85)
        let breath = Float(1 + 0.008 * sin(a.time * 1.35))
        let swell = m?.swell ?? level * (assistantState == .speaking ? 0.065 : 0.025)
        let fire = m?.fire ?? (a.time * 0.5).truncatingRemainder(dividingBy: 400)
        dynamics = SIMD4(breath + Float(swell) * muted, Float(a.speed), Float(fire), Float(m?.density ?? 0))
        let palette = SpherePalette.shared
        primary = simd_mix(simd_mix(palette.cyan, palette.amber, SIMD4(repeating: Float(a.alert))),
                           palette.privacy, SIMD4(repeating: Float(a.privacy)))
        ice = simd_mix(palette.ice, primary, SIMD4(repeating: Float(max(a.alert, a.privacy))))
        deep = simd_mix(palette.deep, primary * 0.45, SIMD4(repeating: Float(max(a.alert, a.privacy))))
    }
}

private struct SpherePalette {
    static let shared = SpherePalette()
    let cyan = rgba(HUD.cyan), ice = rgba(HUD.ice), deep = rgba(HUD.deep)
    let amber = rgba(HUD.amber), privacy = rgba(HUD.privacy)

    private static func rgba(_ color: Color) -> SIMD4<Float> {
        #if os(macOS)
        let c = NSColor(color).usingColorSpace(.deviceRGB) ?? .cyan
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), 1)
        #endif
    }
}

private struct SphereSegment {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var style: SIMD4<Float> // opacity, width in points, flow coordinate, seed
}

private struct SpherePoint {
    var position: SIMD4<Float>
    var style: SIMD4<Float> // radius in points, brightness, seed, kind (0 node / 1 process / 2 core)
}

/// Deterministic topology, built once for each level of detail, shared by all views.
/// Group (the w of each position): 0 turns in 3D with the shell; 1 is the vortex,
/// which spins about the view axis so its spiral always faces the viewer.
private struct SphereGeometry {
    var segments: [SphereSegment] = []
    var points: [SpherePoint] = []
    static let full = SphereGeometry(compact: false)
    static let small = SphereGeometry(compact: true)
    static let fallback: Path = {
        var path = Path()
        for s in small.segments {
            path.move(to: CGPoint(x: CGFloat(s.a.x), y: CGFloat(s.a.y)))
            path.addLine(to: CGPoint(x: CGFloat(s.b.x), y: CGFloat(s.b.y)))
        }
        return path
    }()

    init(compact: Bool) {
        var random = SeededRandom(seed: 0x4A41_5256_4953)
        var segs: [SphereSegment] = [], pts: [SpherePoint] = []
        func r(_ a: Float, _ b: Float) -> Float { a + Float(random.next()) * (b - a) }
        func unit() -> SIMD3<Float> {
            let y = r(-1, 1), angle = r(0, 2 * .pi), s = sqrt(max(0, 1 - y * y))
            return SIMD3(s * cos(angle), y, s * sin(angle))
        }
        func v4(_ p: SIMD3<Float>, _ group: Float) -> SIMD4<Float> { SIMD4(p.x, p.y, p.z, group) }
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, group: Float, opacity: Float, width: Float, flow: Float, seed: Float) {
            segs.append(SphereSegment(a: v4(a, group), b: v4(b, group), style: SIMD4(opacity, width, flow, seed)))
        }
        func dot(_ p: SIMD3<Float>, group: Float, radius: Float, brightness: Float, kind: Float, seed: Float? = nil) {
            pts.append(SpherePoint(position: v4(p, group), style: SIMD4(radius, brightness, seed ?? r(0, 20), kind)))
        }
        /// A soft ribbon: several parallel strands plus two wide, faint passes for the glow.
        /// `plane` set: the strands spread in that plane (vortex); nil: along the sphere surface.
        func ribbon(steps: Int, strands: Int, group: Float, plane: SIMD3<Float>?, glow: Float, seed: Float,
                    width: (Float) -> Float, path: (Float) -> SIMD3<Float>) {
            for strand in 0..<strands {
                let s = strands == 1 ? 0 : Float(strand) / Float(strands - 1) - 0.5
                let wobble = r(0, 6.28)
                let core = 1 - abs(s) * 2
                var previous: SIMD3<Float>?
                for step in 0...steps {
                    let f = Float(step) / Float(steps)
                    let c = path(f)
                    let tangent = simd_normalize(path(min(1, f + 0.01)) - path(max(0, f - 0.01)) + SIMD3(0, 0, 1e-5))
                    var side = simd_cross(tangent, plane ?? simd_normalize(c + SIMD3(1e-4, 1e-4, 0)))
                    side = simd_length(side) < 1e-4 ? SIMD3(0, 0, 1) : simd_normalize(side)
                    let lift = simd_cross(side, tangent)
                    let p = c + side * (s * width(f) + 0.004 * sin(f * 23 + wobble))
                        + lift * (0.012 * abs(s) * sin(f * 17 + wobble * 1.3))
                    if let q = previous {
                        line(q, p, group: group, opacity: 0.30 + 0.26 * core, width: 0.85 + 0.35 * core, flow: f, seed: seed)
                    }
                    previous = p
                }
            }
            guard glow > 0 else { return }
            for step in stride(from: 0, to: steps, by: 2) {
                let a = path(Float(step) / Float(steps)), b = path(Float(min(steps, step + 2)) / Float(steps))
                let f = Float(step) / Float(steps)
                let swell = 0.4 + 0.6 * max(0, sin(.pi * f))
                line(a, b, group: group, opacity: 0.085 * glow * swell, width: 22, flow: f, seed: seed)
                line(a, b, group: group, opacity: 0.15 * glow * swell, width: 7, flow: f, seed: seed)
            }
        }

        // 1. Plexus: nodes in the whole volume, denser on the shell, joined to nearby nodes.
        // The shell holds most of them: seen at the edges, it gives the sphere its rotating outline.
        let nodeCount = compact ? 160 : 1500
        var nodes: [SIMD3<Float>] = []
        for i in 0..<nodeCount {
            let radius: Float = i % 9 == 0 ? r(0.08, 0.35) : i % 5 == 0 ? r(0.35, 0.8) : r(0.84, 0.97)
            let p = unit() * radius
            nodes.append(p)
            dot(p, group: 0, radius: compact ? 1.8 : 2.7, brightness: r(0.8, 1.6), kind: 0)
        }
        // Spatial grid: each node is compared only with the 27 cells around it, not with every node.
        let cell: Float = 0.25
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3(Int32(floor(p.x / cell)), Int32(floor(p.y / cell)), Int32(floor(p.z / cell)))
        }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (i, p) in nodes.enumerated() { grid[key(p), default: []].append(i) }
        for (i, p) in nodes.enumerated() {
            let k = key(p)
            var near: [(Float, Int)] = []
            for dx: Int32 in -1...1 { for dy: Int32 in -1...1 { for dz: Int32 in -1...1 {
                for j in grid[k &+ SIMD3(dx, dy, dz)] ?? [] where j != i { near.append((simd_distance(p, nodes[j]), j)) }
            } } }
            near.sort { $0.0 < $1.0 }
            for (d, j) in near.prefix(compact ? 3 : 4) where j > i && d < cell {
                line(p, nodes[j], group: 0, opacity: r(0.45, 0.72), width: 0.85, flow: r(0, 1), seed: r(0, 20))
            }
        }

        // 2. Neural network (group 2): neurons inside the sphere, with dendrites, joined by
        // soft glowing axons. Each neuron fires in turn: its body flashes and a pulse runs
        // along its axons and dendrites. The seed of every piece is its neuron's firing phase.
        // 44 neurons joined to their three nearest (11 November: the user wanted a denser sphere).
        let neuronCount = compact ? 5 : 44
        var neurons: [(p: SIMD3<Float>, seed: Float)] = []
        for _ in 0..<neuronCount {
            // The first neuron is the heart of the sphere: a larger cell body at the centre, with long branching dendrites.
            let central = !compact && neurons.isEmpty
            var p = SIMD3<Float>.zero
            if !central {
                // Best of eight tries: the one farthest from the neurons already placed, so no side stays empty.
                var best: Float = -1
                for _ in 0..<(compact ? 1 : 8) {
                    let c = unit() * r(0.25, 0.92)
                    let d = neurons.map { simd_distance($0.p, c) }.min() ?? 1
                    if d > best { best = d; p = c }
                }
            }
            let seed = r(0, 1)
            neurons.append((p, seed))
            dot(p, group: 2, radius: compact ? 3.5 : central ? 17 : 8, brightness: central ? 1.5 : r(1.0, 1.3), kind: 3, seed: seed)
            // Dendrites: short branching tendrils around the body.
            for _ in 0..<(compact ? 2 : central ? 12 : 6) {
                var direction = unit(), q = p
                for level in 0..<(compact ? 2 : 3) {
                    let length = (level == 0 ? r(0.10, 0.2) : level == 1 ? r(0.05, 0.1) : r(0.03, 0.07)) * (central ? 1.9 : 1), bend = unit() * 0.6
                    var previous = q
                    for step in 1...8 {
                        let f = Float(step) / 8
                        let next = q + simd_normalize(direction + bend * f) * length * f
                        line(previous, next, group: 2, opacity: 0.5 * (1 - f * 0.5), width: (level == 0 ? 0.9 : 0.7) * (central ? 2.2 : 1),
                             flow: (Float(level) + f) * 0.12, seed: seed)
                        previous = next
                    }
                    q = previous
                    if level < 2 && !compact { dot(q, group: 2, radius: central ? 3 : 2, brightness: 0.9, kind: 0) }
                    direction = simd_normalize(direction + unit() * 0.9)
                }
            }
        }
        // Axons: each neuron to its nearest ones (three in the full sphere) and, sometimes, to a far one.
        var joined = Set<Int>()
        for (i, n) in neurons.enumerated() {
            let near = neurons.indices.filter { $0 != i }.sorted {
                simd_distance(n.p, neurons[$0].p) < simd_distance(n.p, neurons[$1].p)
            }
            var targets = Array(near.prefix(compact ? 2 : 3))
            if random.next() < 0.35, let far = near.last { targets.append(far) }
            for j in targets where !joined.contains(min(i, j) * 100 + max(i, j)) {
                joined.insert(min(i, j) * 100 + max(i, j))
                let a = n.p, b = neurons[j].p
                // Like brain tissue: some axons run almost straight, others bend in any direction.
                let control = (a + b) / 2 + unit() * simd_distance(a, b) * (random.next() < 0.45 ? 0.05 : 0.35)
                let path: (Float) -> SIMD3<Float> = { f in
                    var p = a * (1 - f) * (1 - f) + control * 2 * f * (1 - f) + b * f * f
                    let l = simd_length(p)
                    if l > 0.95 { p *= 0.95 / l }
                    return p
                }
                ribbon(steps: compact ? 16 : 44, strands: compact ? 2 : 6, group: 2, plane: nil, glow: 1, seed: n.seed,
                       width: { f in 0.006 + 0.032 * pow(max(0, sin(.pi * f)), 0.8) }, path: path)
            }
        }

        // 3. Ribbons wrapping the shell: they give the sphere its outline.
        for _ in 0..<(compact ? 4 : 13) {
            let axis = unit()
            let right = simd_normalize(simd_cross(axis, abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
            let up = simd_cross(axis, right)
            let start = r(0, 2 * .pi), span = r(2.2, 4.2), seed = r(0, 20), radius = r(0.84, 0.93), wave = r(0.25, 0.5)
            ribbon(steps: compact ? 36 : 110, strands: compact ? 3 : 8, group: 0, plane: nil, glow: 0.8, seed: seed,
                   width: { f in 0.012 + 0.06 * pow(max(0, sin(.pi * f)), 0.7) }) { f in
                let t = start + span * f
                return simd_normalize(right * cos(t) + up * sin(t) + axis * wave * sin(t * 2 + seed)) * radius
            }
        }

        // 5. Broken rim: short dashes just outside the shell, always on the outline.
        for _ in 0..<(compact ? 14 : 0) {
            let angle = r(0, 2 * .pi), length = r(0.015, 0.07), radius = r(0.95, 1.05), seed = r(0, 20)
            let thick = random.next() < 0.3
            line(SIMD3(radius * cos(angle), radius * sin(angle), 0), SIMD3(radius * cos(angle + length), radius * sin(angle + length), 0),
                 group: 1, opacity: thick ? 0.95 : 0.6, width: thick ? 3 : 1.2, flow: r(0, 1), seed: seed)
        }

        // 6. Small data screens (bars, waveforms, scrolling lines) on the shell and a few inside.
        // They turn with the sphere; none circles around the outline.
        for i in 0..<(compact ? 6 : 8) {
            dot(unit() * (i % 3 == 0 ? r(0.3, 0.8) : r(0.85, 0.98)), group: 0, radius: r(4, 7), brightness: r(0.65, 1), kind: 1)
        }

        // 7. Core: a wide halo and a white-hot centre. Analytic sprites, no blur.
        dot(.zero, group: 1, radius: compact ? 16 : 46, brightness: 1.0, kind: 2)
        dot(.zero, group: 1, radius: compact ? 6 : 9, brightness: 1.2, kind: 2)
        segments = segs
        points = pts
    }
}

private final class SphereGPU {
    static let shared: SphereGPU? = {
        do { return try SphereGPU() }
        catch { NSLog("JARVIS sphere: Metal unavailable (%@); using static fallback", String(describing: error)); return nil }
    }()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let lines: MTLRenderPipelineState
    let dots: MTLRenderPipelineState
    let full: Mesh
    let small: Mesh

    struct Mesh {
        let segments: MTLBuffer
        let points: MTLBuffer
        let segmentCount: Int
        let pointCount: Int
        init(device: MTLDevice, geometry: SphereGeometry) throws {
            guard let s = device.makeBuffer(bytes: geometry.segments,
                    length: geometry.segments.count * MemoryLayout<SphereSegment>.stride, options: .storageModeShared),
                  let p = device.makeBuffer(bytes: geometry.points,
                    length: geometry.points.count * MemoryLayout<SpherePoint>.stride, options: .storageModeShared) else {
                throw Failure.unavailable
            }
            segments = s; points = p
            segmentCount = geometry.segments.count; pointCount = geometry.points.count
            segments.label = "JARVIS fixed filaments"; points.label = "JARVIS fixed nodes"
        }
    }
    enum Failure: Error { case unavailable }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailable
        }
        self.device = device; self.queue = queue
        // Embedded MSL keeps SwiftPM packaging and the change confined to Reactor.swift.
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
            // Premultiplied alpha union: transparent windows composite without black rectangles.
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        lines = try pipeline("sphereLine", "filament")
        dots = try pipeline("spherePoint", "spark")
        full = try Mesh(device: device, geometry: .full)
        small = try Mesh(device: device, geometry: .small)
    }

    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                uniforms: SphereUniforms, compact: Bool) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "JARVIS sphere: two draws, no bloom"
        let mesh = compact ? small : full
        var values = uniforms
        encoder.setVertexBytes(&values, length: MemoryLayout<SphereUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&values, length: MemoryLayout<SphereUniforms>.stride, index: 1)
        encoder.setRenderPipelineState(lines)
        encoder.setVertexBuffer(mesh.segments, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: mesh.segmentCount)
        encoder.setRenderPipelineState(dots)
        encoder.setVertexBuffer(mesh.points, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: mesh.pointCount)
        encoder.endEncoding()
    }

    static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 motion, state, rotation, viewport, primary, ice, deep, dynamics; };
    struct Segment { float4 a, b, style; };
    struct Point { float4 position, style; };
    struct Out {
        float4 position [[position]];
        float2 uv;
        float brightness;
        float seed;
        float kind;
    };
    constant float2 corners[6] = {float2(-1,-1),float2(1,-1),float2(-1,1),
                                  float2(-1,1),float2(1,-1),float2(1,1)};
    // motion: time, phase, energy, smoothed level. state: boot, alert, privacy, flow phase.
    // dynamics: scale, speed, firing clock, pulse density (0 = one pulse, 1 = three per path).
    // Groups (w of positions): 0 shell, 1 rim and core (turn about the view axis), 2 neurons.
    float3 project(float4 q, constant Uniforms &u) {
        float3 p = q.xyz;
        float live = 1.0 - u.state.z * 0.85;
        float ripple = sin(dot(p,float3(4,7,3)) - u.motion.y * 2.5);
        p *= u.dynamics.x + ripple * (u.motion.w * 0.018 + (u.dynamics.x - 1.0) * 0.55) * live;
        if (q.w < 0.5 || q.w > 1.5) {
            // A slow, even breathing: one wide wave crosses the whole sphere, barely changing its shape.
            float t = u.motion.x;
            float wave = sin(dot(p,float3(1.1,0.8,0.9)) + t*0.55) * 0.7 + sin(t*0.4) * 0.3;
            p *= 1.0 + wave * 0.014 * (0.6 + 0.4 * live);
        }
        if (q.w > 0.5 && q.w < 1.5) {
            // Rim and core: turn about the view axis, so they always sit on the outline.
            float s = -u.motion.y * 0.30, cs = cos(s), sn = sin(s);
            p.xy = float2(p.x*cs - p.y*sn, p.x*sn + p.y*cs);
            float t = 0.16 * sin(u.motion.y * 0.09), w = 0.18 * sin(u.motion.y * 0.07);
            p.yz = float2(p.y*cos(t) - p.z*sin(t), p.y*sin(t) + p.z*cos(t));
            p.xz = float2(p.x*cos(w) + p.z*sin(w), -p.x*sin(w) + p.z*cos(w));
        } else {
            p.xz = float2(p.x*u.rotation.x + p.z*u.rotation.y, -p.x*u.rotation.y + p.z*u.rotation.x);
            p.yz = float2(p.y*u.rotation.z - p.z*u.rotation.w, p.y*u.rotation.w + p.z*u.rotation.z);
        }
        float reveal = smoothstep(0.0, 0.85, u.state.x);
        float scale = 0.93 * (0.86 + 0.14 * reveal) / (1.12 - p.z*0.16);
        float2 aspect = min(u.viewport.x,u.viewport.y) / u.viewport.xy;
        return float3(p.xy * scale * aspect, p.z);
    }
    float pulseAt(float beat) { return pow(max(0.0, 1.0 - abs(beat - 0.5) * 2.0), 14.0); }
    // Where a neuron is in its firing cycle: 0 = it fires now. Every neuron fires every
    // 4 units of the firing clock, each with its own phase (the seed).
    float cycleOf(float seed, constant Uniforms &u) { return fract(u.dynamics.z * 0.25 + seed); }
    // A pulse running along an axon or dendrite (coordinate 0 at the neuron that fires).
    float fire(float coordinate, float seed, constant Uniforms &u) {
        float cycle = cycleOf(seed, u);
        float d = (coordinate - cycle / 0.4) * 9.0;
        float pulse = exp(-d * d) * (1.0 - smoothstep(0.38, 0.45, cycle));
        float lit = 0.22 * (1.0 - smoothstep(0.3, 0.45, cycle)) * smoothstep(0.0, 0.03, cycle);
        float active = (0.6 + u.motion.z * 0.5) * (1.0 - u.state.z * 0.8);
        return 0.65 + (pulse * 3.2 + lit) * active;
    }
    // Edges of the shell are brighter: the sphere reads as a solid that turns.
    float limb(float3 original, float z) {
        float r = length(original);
        float l = 1.0 - min(1.0, abs(z) / max(r, 0.2));
        return mix(1.0, mix(0.8, 1.5, l * l), smoothstep(0.7, 0.85, r));
    }
    // Phase and density come smoothed from Swift: a change of state never makes pulses jump.
    float flow(float coordinate, float seed, constant Uniforms &u) {
        float shift = u.state.w + seed;
        float pulse = mix(pulseAt(fract(coordinate + shift)), pulseAt(fract(coordinate * 3.0 + shift)), u.dynamics.w);
        float active = (0.22 + u.motion.z * 0.65 + min(u.dynamics.y,2.1)*0.12) * (1.0-u.state.z*0.8);
        return 0.60 + pulse * active * 2.3;
    }
    vertex Out sphereLine(uint id [[vertex_id]], uint instance [[instance_id]],
                          const device Segment *segments [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        Segment s = segments[instance];
        float2 corner = corners[id];
        float3 a = project(s.a,u), b = project(s.b,u);
        float2 direction = (b.xy-a.xy)*u.viewport.xy;
        float2 normal = float2(-direction.y,direction.x) / max(length(direction),0.001);
        float3 p = mix(a,b,(corner.x+1.0)*0.5);
        float width = s.style.y * u.viewport.z * (1.0+u.motion.w*0.3);
        Out out;
        out.position = float4(p.xy + normal * corner.y * max(width,0.75) / u.viewport.xy, 0, 1);
        out.uv = float2(corner.x,corner.y);
        float motion = s.a.w > 1.5 ? fire(s.style.z, s.style.w, u) : flow(s.style.z, s.style.w, u);
        float edge = s.a.w < 0.5 ? limb(s.a.xyz, p.z) : 1.0;
        out.brightness = s.style.x * (0.45+0.55*smoothstep(-0.95,0.9,p.z)) * edge
                         * motion * smoothstep(0.04,0.85,u.state.x);
        out.seed=s.style.w; out.kind=0;
        return out;
    }
    fragment float4 filament(Out in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float coverage = exp(-in.uv.y*in.uv.y*3.8);
        float alpha = saturate(in.brightness * coverage * (0.75+u.motion.z*0.5));
        float3 color = mix(mix(u.deep.rgb,u.primary.rgb,0.95),u.ice.rgb,min(in.brightness*0.35,0.6));
        return float4(color*alpha,alpha);
    }
    vertex Out spherePoint(uint id [[vertex_id]], uint instance [[instance_id]],
                           const device Point *points [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        Point point=points[instance]; float2 corner=corners[id];
        float3 p=project(point.position,u);
        float core=step(1.5,point.style.w)*step(point.style.w,2.5);
        float soma=step(2.5,point.style.w);
        // A neuron flashes when it fires, and glows a little just before.
        float cycle=cycleOf(point.style.z,u);
        float flash=soma*(exp(-cycle*9.0)+0.35*exp(-(1.0-cycle)*30.0))*(1.0-u.state.z*0.8);
        float radius=point.style.x*u.viewport.z*(1.0+u.motion.w*(core>0.5 ? 0.8 : 0.3))*(1.0+0.7*flash);
        float2 extent=point.style.w==1.0 ? float2(2.0,1.25) : float2(1.0);
        Out out;
        out.position=float4(p.xy + corner*extent*radius*2.0/u.viewport.xy,0,1);
        out.uv=corner; out.seed=point.style.z; out.kind=point.style.w;
        float twinkle=0.72+0.28*sin(u.motion.y*2.0+point.style.z);
        float edge=point.position.w<0.5 ? limb(point.position.xyz,p.z) : 1.0;
        out.brightness=point.style.y*mix(0.4+0.6*smoothstep(-0.9,0.9,p.z),1.0,core)*edge
                      *mix(twinkle,1.0,max(core,soma))*(1.0+2.2*flash)*smoothstep(0.0,0.7,u.state.x);
        return out;
    }
    fragment float4 spark(Out in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float r=length(in.uv);
        float alpha; float3 color;
        if(in.kind>2.5) {
            // Neuron body: halo and bright centre, white while it fires.
            alpha=(exp(-r*r*4.0)*0.45+exp(-r*r*28.0)*1.0)*in.brightness;
            color=mix(mix(u.primary.rgb,u.ice.rgb,exp(-r*r*10.0)),float3(1.0),saturate(in.brightness-1.2)*exp(-r*r*30.0));
            alpha=saturate(alpha)*(1.0-smoothstep(0.85,1.0,r));
        } else if(in.kind>1.5) {
            // Core: wide halo, bright body, white-hot centre.
            float halo=exp(-r*r*5.0)*0.42 + exp(-r*r*22.0)*0.45;
            float center=exp(-r*r*140.0)*1.2;
            alpha=(halo+center)*(0.75+u.motion.z*0.25+u.motion.w*0.5)*in.brightness;
            color=mix(mix(u.primary.rgb,u.ice.rgb,exp(-r*r*18.0)),float3(1.0),exp(-r*r*90.0));
            alpha=saturate(alpha)*(1.0-smoothstep(0.85,1.0,r));
        } else if(in.kind>0.5) {
            // Small data screen: a frame and, inside, live bars, a waveform or scrolling lines.
            float2 q=abs(in.uv);
            float inside=(1.0-smoothstep(0.9,1.0,q.x))*(1.0-smoothstep(0.86,1.0,q.y));
            float frame=smoothstep(0.76,0.9,max(q.x,q.y));
            float2 t=in.uv*0.5+0.5;
            float kind=fract(in.seed*7.31), now=u.motion.x, content;
            if(kind<0.34) {
                float bucket=floor(t.x*6.0);
                float level=0.2+0.65*(0.5+0.5*sin(now*2.2+bucket*1.9+in.seed));
                content=step(t.y,level)*step(0.22,fract(t.x*6.0))*step(0.12,t.y);
            } else if(kind<0.67) {
                float y=0.5+0.3*sin(t.x*9.0+now*3.0+in.seed)*(0.6+0.4*sin(t.x*3.0-now));
                content=1.0-smoothstep(0.0,0.11,abs(t.y-y));
            } else {
                float rowsY=t.y*4.0+now*1.2;
                float row=floor(rowsY);
                float width=0.3+0.62*fract(sin(row*12.9898+in.seed*78.233)*43758.5453);
                content=step(t.x,width)*step(0.12,t.x)*step(0.3,fract(rowsY))*step(fract(rowsY),0.72);
            }
            alpha=saturate(inside*(0.10+0.55*frame+0.75*content*(1.0-frame))*in.brightness);
            color=mix(u.primary.rgb,u.ice.rgb,0.25+0.35*content);
        } else {
            alpha=(exp(-r*r*6.0)*0.45+exp(-r*r*45.0)*0.95)*in.brightness
                   *(0.75+u.motion.z*0.3+u.motion.w*0.4);
            color=mix(u.primary.rgb,u.ice.rgb,exp(-r*r*8.0));
            alpha=saturate(alpha)*(1.0-smoothstep(0.85,1.0,r));
        }
        return float4(color*alpha,alpha);
    }
    """#
}

// MARK: - Classic reactor for the NUCLEUS desktop widget

/// The NUCLEUS keeps the original reactor: only the open HUD shows the new sphere.
private struct ClassicReactorView: View {
    @ObservedObject var assistant: Assistant
    var paused = false
    @State private var animator = ReactorAnimator()

    var body: some View {
        // 30 fps while active, 12 while waiting, 6 after a minute; stopped when hidden.
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { timeline in
            Canvas { context, size in
                animator.step(timeline.date, state: assistant.state, deepIdle: assistant.deepIdle, privacy: assistant.privacyMode,
                              mic: assistant.levels.mic, voice: assistant.levels.voice)
                ClassicReactorRenderer(context: context, size: size, a: animator, compact: true).draw()
            }
            .drawingGroup()
        }
    }

    private var frameInterval: Double {
        guard assistant.state == .idle else { return 1.0 / 30 }
        return assistant.deepIdle ? 1.0 / 6 : 1.0 / 12
    }
}

private struct ClassicReactorRenderer {
    let context: GraphicsContext
    let size: CGSize
    let a: ReactorAnimator
    /// In the NUCLEUS no outer brackets: only the reactor itself remains.
    var compact = false

    var c: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var R: CGFloat { min(size.width, size.height) / 2 * 0.96 }

    /// Normal cyan, amber on error, grey in privacy mode.
    var primary: Color { a.privacy > 0.5 ? HUD.privacy : a.alert > 0.5 ? HUD.amber : HUD.cyan }
    var e: Double { a.energy }
    var lv: Double { a.level }

    /// Each ring appears during start-up with a slight delay after the previous one.
    func reveal(_ index: Int) -> Double {
        let t = (a.boot - Double(index) * 0.07) / 0.45
        let x = max(0, min(1, t))
        return 1 - pow(1 - x, 3)
    }

    func draw() {
        var glow = context
        glow.blendMode = .plusLighter
        // The glow (a blur over the whole reactor) is by far the most expensive
        // effect: it turns off while waiting, and comes back when JARVIS listens or speaks.
        if e > 0.6 { glow.addFilter(.shadow(color: primary.opacity(0.9 * min(1, (e - 0.6) * 4)), radius: 5)) }
        var soft = context
        soft.blendMode = .plusLighter

        drawCoreGlow(soft)
        if !compact { drawBrackets(glow, reveal(8)) }
        drawDataRing(soft, reveal(7))
        drawSpectrum(glow, reveal(6))
        drawScanner(glow, reveal(5))
        drawHeavyArcs(glow, reveal(4))
        drawTickRing(soft, reveal(3))
        drawCoils(glow, reveal(2))
        drawCore(glow, reveal(1))
        drawParticles(soft, reveal(5))
    }

    // MARK: Primitives

    func arc(_ ctx: GraphicsContext, r: CGFloat, from: Double, to: Double, width: CGFloat, color: Color) {
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .radians(from), endAngle: .radians(to), clockwise: false)
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .butt))
    }

    func circle(_ ctx: GraphicsContext, r: CGFloat, width: CGFloat, color: Color, dash: [CGFloat] = []) {
        let p = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
    }

    func radial(_ ctx: GraphicsContext, angle: Double, r1: CGFloat, r2: CGFloat, width: CGFloat, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: c.x + cos(angle) * r1, y: c.y + sin(angle) * r1))
        p.addLine(to: CGPoint(x: c.x + cos(angle) * r2, y: c.y + sin(angle) * r2))
        ctx.stroke(p, with: .color(color), lineWidth: width)
    }

    /// Adds a radial line to a path: many lines in the same
    /// path become a single drawing operation, much lighter.
    func addRadial(_ p: inout Path, angle: Double, r1: CGFloat, r2: CGFloat) {
        p.move(to: point(angle, r1))
        p.addLine(to: point(angle, r2))
    }

    func addArc(_ p: inout Path, r: CGFloat, from: Double, to: Double) {
        p.move(to: point(from, r))
        p.addArc(center: c, radius: r, startAngle: .radians(from), endAngle: .radians(to), clockwise: false)
    }

    func point(_ angle: Double, _ r: CGFloat) -> CGPoint {
        CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
    }

    // MARK: Layers

    func drawCoreGlow(_ ctx: GraphicsContext) {
        let r = R * (0.62 + lv * 0.12)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [primary.opacity(0.32 * e), HUD.deep.opacity(0.10 * e), .clear]),
            center: c, startRadius: 0, endRadius: r))
    }

    func drawOuterScale(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let r = R * 0.985 * v
        circle(ctx, r: r, width: 0.6, color: primary.opacity(0.28 * v))
        circle(ctx, r: r * 0.955, width: 0.5, color: primary.opacity(0.16 * v))
        let rot = -a.phase * 0.02
        var major = Path(), minor = Path()
        for i in 0..<180 {
            let ang = rot + Double(i) / 180 * .pi * 2
            if i % 15 == 0 { addRadial(&major, angle: ang, r1: r - R * 0.035, r2: r) }
            else { addRadial(&minor, angle: ang, r1: r - R * (i % 5 == 0 ? 0.02 : 0.01), r2: r) }
        }
        ctx.stroke(major, with: .color(primary.opacity(0.7 * v)), lineWidth: 1.2)
        ctx.stroke(minor, with: .color(primary.opacity(0.35 * v)), lineWidth: 0.6)
        for i in 0..<12 {
            let ang = rot + Double(i) / 12 * .pi * 2
            let label = Text(String(format: "%03d", i * 30)).font(HUD.mono(R * 0.026)).foregroundColor(primary.opacity(0.55 * v))
            ctx.draw(label, at: point(ang, r - R * 0.065))
        }
    }

    func drawBrackets(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let r = R * 0.885 * v
        let rot = a.phase * 0.07
        for k in 0..<4 {
            let mid = rot + Double(k) * .pi / 2 + .pi / 4
            let half = 0.36
            arc(ctx, r: r, from: mid - half, to: mid + half, width: 2.2, color: primary.opacity(0.85 * v))
            for end in [mid - half, mid + half] {
                radial(ctx, angle: end, r1: r - R * 0.025, r2: r + R * 0.012, width: 2.2, color: primary.opacity(0.85 * v))
            }
            // Small triangular marker in the middle of each bracket.
            var tri = Path()
            tri.move(to: point(mid, r + R * 0.02))
            tri.addLine(to: point(mid - 0.025, r + R * 0.045))
            tri.addLine(to: point(mid + 0.025, r + R * 0.045))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(primary.opacity(0.8 * v)))
        }
        arc(ctx, r: r * 0.975, from: -rot * 1.3, to: -rot * 1.3 + 1.1, width: 0.8, color: HUD.ice.opacity(0.5 * v))
    }

    /// Outer ring of segments. Each segment is a solid block; the light
    /// does not change randomly but flows in continuous waves along the ring (faster
    /// when JARVIS works), so even at few frames per second it is smooth.
    func drawDataRing(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let r = R * 0.775 * v
        let inner = r - R * 0.011, outer = r + R * 0.011
        let segments = 72
        let slot = .pi * 2 / Double(segments)
        let rot = -a.phase * 0.06
        let flow = a.time * (0.5 + e * 1.6)
        // Four brightness levels: few paths to draw, enough shading.
        var levels = [Path](repeating: Path(), count: 4)
        for i in 0..<segments {
            let x = Double(i) / Double(segments)
            let wave = 0.5 + 0.5 * sin(.pi * 2 * x * 3 - flow)
            let level = min(3, Int(pow(wave, 2.2) * 4))
            let start = rot + Double(i) * slot
            addSector(&levels[level], from: start, to: start + slot * 0.72, inner: inner, outer: outer)
        }
        for (level, path) in levels.enumerated() {
            ctx.fill(path, with: .color(primary.opacity([0.12, 0.24, 0.40, 0.62][level] * v)))
        }
        circle(ctx, r: inner - R * 0.006, width: 0.5, color: primary.opacity(0.3 * v))
        circle(ctx, r: outer + R * 0.006, width: 0.5, color: primary.opacity(0.3 * v))
    }

    /// Solid ring sector between two angles and two radii.
    func addSector(_ p: inout Path, from start: Double, to end: Double, inner: CGFloat, outer: CGFloat) {
        p.move(to: point(start, inner))
        p.addArc(center: c, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        p.closeSubpath()
    }

    func drawSpectrum(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let base = R * 0.64 * v
        let bars = 128
        let t = a.time
        var outer = Path(), inner = Path()
        for i in 0..<bars {
            let ang = Double(i) / Double(bars) * .pi * 2 - .pi / 2
            let n = 0.5 + 0.5 * sin(Double(i) * 0.71 + t * 7.3) * cos(Double(i) * 0.23 - t * 4.1)
            let breath = 0.012 + 0.008 * sin(t * 1.4 + Double(i) * 0.3)
            let len = R * (breath + lv * 0.17 * (0.25 + 0.75 * n))
            addRadial(&outer, angle: ang, r1: base, r2: base + len)
            addRadial(&inner, angle: ang, r1: base - len * 0.25, r2: base)
        }
        let bright = 0.35 + 0.65 * min(1, lv * 1.6)
        ctx.stroke(outer, with: .color(primary.opacity(bright * v)), lineWidth: 1.6)
        ctx.stroke(inner, with: .color(primary.opacity(0.35 * bright * v)), lineWidth: 1)
    }

    func drawScanner(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let r = R * 0.535 * v
        circle(ctx, r: r, width: 0.7, color: primary.opacity(0.35 * v))
        // Comet: a bright arc with a fading trail.
        let head = a.phase * 1.4
        let steps = 24
        for s in 0..<steps {
            let f = Double(s) / Double(steps)
            let from = head - 1.6 * (1 - f)
            arc(ctx, r: r, from: from, to: from + 1.6 / Double(steps) + 0.01, width: 2.4,
                color: HUD.ice.opacity(pow(f, 2) * (0.25 + 0.75 * e) * v))
        }
        circle(ctx, r: r - R * 0.03, width: 0.5, color: primary.opacity(0.25 * v), dash: [2, 5])
    }

    func drawHeavyArcs(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let r = R * 0.445 * v
        let rot = -a.phase * 0.45
        let spans: [(Double, Double)] = [(0, 1.25), (1.7, 0.85), (3.05, 0.55), (4.1, 1.5)]
        for (offset, span) in spans {
            arc(ctx, r: r, from: rot + offset, to: rot + offset + span, width: R * 0.03,
                color: primary.opacity((0.55 + 0.35 * e) * v))
        }
        circle(ctx, r: r - R * 0.03, width: 0.8, color: primary.opacity(0.4 * v))
        let rot2 = a.phase * 0.8
        for k in 0..<3 {
            let s = rot2 + Double(k) * 2.094
            arc(ctx, r: r + R * 0.035, from: s, to: s + 0.5, width: 1.2, color: HUD.ice.opacity(0.6 * v))
        }
    }

    /// Ring of ticks around the coils. They are small solid rectangles (not thin
    /// lines, which flicker as they rotate) and spin slowly, so the movement stays
    /// smooth even at few frames per second.
    func drawTickRing(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let r = R * 0.355 * v
        let rot = a.phase * 0.18
        var major = Path(), minor = Path()
        for i in 0..<60 {
            let ang = rot + Double(i) / 60 * .pi * 2
            if i % 5 == 0 { addTick(&major, angle: ang, r1: r, length: R * 0.045, width: 2.6) }
            else { addTick(&minor, angle: ang, r1: r, length: R * 0.022, width: 1.6) }
        }
        ctx.fill(major, with: .color(primary.opacity(0.85 * v)))
        ctx.fill(minor, with: .color(primary.opacity(0.45 * v)))
    }

    /// Small rectangle facing the centre, `width` points wide.
    func addTick(_ p: inout Path, angle: Double, r1: CGFloat, length: CGFloat, width: CGFloat) {
        let half = width / 2
        let (dx, dy) = (CGFloat(cos(angle)), CGFloat(sin(angle)))
        let (nx, ny) = (-dy * half, dx * half)
        let a = CGPoint(x: c.x + dx * r1, y: c.y + dy * r1)
        let b = CGPoint(x: c.x + dx * (r1 + length), y: c.y + dy * (r1 + length))
        p.move(to: CGPoint(x: a.x + nx, y: a.y + ny))
        p.addLine(to: CGPoint(x: b.x + nx, y: b.y + ny))
        p.addLine(to: CGPoint(x: b.x - nx, y: b.y - ny))
        p.addLine(to: CGPoint(x: a.x - nx, y: a.y - ny))
        p.closeSubpath()
    }

    /// Trapezoidal coils around the core, like a reactor.
    func drawCoils(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let r1 = R * 0.17 * v, r2 = R * 0.27 * v
        let count = 10
        let rot = -a.phase * 0.12
        for i in 0..<count {
            let mid = rot + Double(i) / Double(count) * .pi * 2
            let w1 = 0.19, w2 = 0.16
            var p = Path()
            p.move(to: point(mid - w1, r1))
            p.addLine(to: point(mid - w2, r2))
            p.addLine(to: point(mid + w2, r2))
            p.addLine(to: point(mid + w1, r1))
            p.closeSubpath()
            ctx.fill(p, with: .color(primary.opacity((0.18 + 0.25 * e + 0.3 * lv) * v)))
            ctx.stroke(p, with: .color(primary.opacity(0.85 * v)), lineWidth: 1)
        }
        circle(ctx, r: r2 + R * 0.012, width: 1.5, color: primary.opacity(0.9 * v))
        circle(ctx, r: r1 - R * 0.012, width: 1.2, color: primary.opacity(0.8 * v))
    }

    func drawCore(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        let pulse = 1 + lv * 0.35 + 0.04 * sin(a.time * 2.2)
        let r = R * 0.13 * pulse * v
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.95 * v), HUD.ice.opacity(0.8 * v), primary.opacity(0.5 * v), .clear]),
            center: c, startRadius: 0, endRadius: r))
        circle(ctx, r: R * 0.075 * v, width: 1.5, color: .white.opacity(0.85 * v))
    }

    func drawParticles(_ ctx: GraphicsContext, _ v: Double) {
        guard v > 0 else { return }
        var buckets = [Path](repeating: Path(), count: 4)
        for p in a.particles {
            let ang = p.angle + a.phase * p.speed
            let pos = point(ang, R * p.radius * v)
            let tw = 0.5 + 0.5 * sin(a.time * 2 + p.twinkle)
            let s = p.size * (1 + lv * 0.6)
            buckets[min(3, Int(tw * 4))].addEllipse(in: CGRect(x: pos.x - s / 2, y: pos.y - s / 2, width: s, height: s))
        }
        for (i, path) in buckets.enumerated() {
            ctx.fill(path, with: .color(HUD.ice.opacity((0.3 + 0.7 * Double(i) / 3) * 0.7 * v)))
        }
    }
}
