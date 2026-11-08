import SwiftUI

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

/// The holographic reactor at the centre of the HUD, drawn on every frame.
struct ReactorView: View {
    @ObservedObject var assistant: Assistant
    /// Small version (reactor mode): no degree scale, it would be unreadable.
    var compact = false
    /// The animation stops when the window containing it is not visible.
    var paused = false
    @State private var animator = ReactorAnimator()

    var body: some View {
        ZStack {
            // The outer degree scale is fixed: it is drawn only once.
            if !compact {
                Canvas { context, size in
                    var soft = context
                    soft.blendMode = .plusLighter
                    ReactorRenderer(context: context, size: size, a: ReactorAnimator()).drawOuterScale(soft, 1)
                }
            }
            // 30 frames per second while listening or speaking, 12 while waiting and 6 after
            // a minute of waiting (rotations are very slow: to the eye little changes).
            // With the window hidden or covered the animation stops completely.
            TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { timeline in
                Canvas { context, size in
                    animator.step(timeline.date, state: assistant.state, deepIdle: assistant.deepIdle, privacy: assistant.privacyMode,
                                  mic: assistant.levels.mic, voice: assistant.levels.voice)
                    ReactorRenderer(context: context, size: size, a: animator, compact: compact).draw()
                }
                .drawingGroup()
            }
        }
    }

    private var frameInterval: Double {
        guard assistant.state == .idle else { return 1.0 / 30 }
        return assistant.deepIdle ? 1.0 / 6 : 1.0 / 12
    }
}

private struct ReactorRenderer {
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
