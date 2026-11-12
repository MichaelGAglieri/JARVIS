import AppKit
import SceneKit
import SwiftUI

/// "Satellite" style of the NUCLEUS: a small 3D satellite built in code with SceneKit
/// (no external models or images), a port of the approved three.js preview. It follows JARVIS's state and the real voice level.
/// 30 fps at most while active, fewer while waiting, stopped when the NUCLEUS is hidden.
struct SatelliteView: NSViewRepresentable {
    @ObservedObject var assistant: Assistant
    var paused: Bool

    func makeNSView(context: Context) -> SatelliteSCNView {
        let view = SatelliteSCNView(frame: NSRect(x: 0, y: 0, width: ReactorPanel.size, height: ReactorPanel.size))
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.rig.levels = assistant.levels
        view.scene = view.rig.scene
        view.delegate = view.rig
        view.pointOfView = view.rig.cameraNode
        update(view)
        return view
    }

    func updateNSView(_ view: SatelliteSCNView, context: Context) { update(view) }

    private func update(_ view: SatelliteSCNView) {
        view.rig.setInputs(state: assistant.state, deepIdle: assistant.deepIdle, privacy: assistant.privacyMode)
        // Waiting: 15 fps without antialiasing (the motion is slow, it stays smooth); active: 30 fps, 2x antialiasing.
        let active = assistant.state != .idle
        let fps = active ? 30 : assistant.deepIdle ? 10 : 15
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
        let aa: SCNAntialiasingMode = active ? .multisampling2X : .none
        if view.antialiasingMode != aa { view.antialiasingMode = aa }
        view.rig.scene.isPaused = paused
        view.isPlaying = !paused
        view.rendersContinuously = !paused
    }
}

/// Mouse events go to the NUCLEUS window (click opens the HUD, drag moves it), not to SceneKit.
final class SatelliteSCNView: SCNView {
    let rig = SatelliteRig()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

/// Builds the scene and animates it on SceneKit's render thread.
/// A faithful port of the three.js preview the user approved (same sizes in metres-like units,
/// same physically based materials, canvas-like textures and per-state motion).
final class SatelliteRig: NSObject, SCNSceneRendererDelegate {
    enum Mode { case idle, listening, thinking, speaking }

    let scene = SCNScene()
    let cameraNode = SCNNode()
    weak var levels: AudioLevels?

    // Inputs from the main thread.
    private let lock = NSLock()
    private var mode = Mode.idle
    private var accent = SatelliteRig.blue
    private var appliedAccent: NSColor?

    private var last: TimeInterval?
    /// Smoothed values, like `L()` in the preview.
    private var cur: [String: CGFloat] = [:]
    private var voice: CGFloat = 0

    // Animated parts.
    private let root = SCNNode(), sat = SCNNode()
    private var ring = SCNNode(), ring2 = SCNNode()
    private var segs: [SCNNode] = [], blades: [SCNNode] = [], brows: [SCNNode] = [], mouth: [SCNNode] = []
    private var iris = SCNNode(), iris2 = SCNNode(), irisG = SCNNode()
    private var wings: [(arm: SCNNode, p1: SCNNode, panels: [SCNNode], d: CGFloat, tg: SCNNode)] = []
    private var dish = SCNNode(), dsh = SCNNode(), ftip = SCNNode()
    private var trackers: [SCNNode] = []
    private var ledG = SCNNode(), strobeG = SCNNode(), engG = SCNNode()
    private var thrusters: [SCNNode] = []
    private var particles: [(node: SCNNode, a: CGFloat, r: CGFloat, y: CGFloat, s: CGFloat)] = []
    private let particleGroup = SCNNode()
    private var waves: [SCNNode] = []
    private var random = SatelliteRandom(seed: 5)

    static let blue = NSColor(srgbRed: 0x4c / 255, green: 0xc2 / 255, blue: 1, alpha: 1)
    private static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    // Materials (MeshStandardMaterial → physically based).
    private lazy var glowTexture = Self.radialTexture()
    private let BLU = SatelliteRig.pbr(SatelliteRig.blue, metal: 0, rough: 0.5)
    private lazy var HULL = Self.pbr(Self.hexTexture(), metal: 0.95, rough: 0.18, repeatU: 2)
    private let TI = SatelliteRig.pbr(SatelliteRig.hex(0x9aa3af), metal: 1, rough: 0.16)
    private let TI2 = SatelliteRig.pbr(SatelliteRig.hex(0xdde3ea), metal: 1, rough: 0.16)
    private let DK = SatelliteRig.pbr(SatelliteRig.hex(0x151a22), metal: 0.7, rough: 0.42)
    private lazy var FOIL = Self.pbr(Self.foilTexture(), metal: 1, rough: 0.3, repeatU: 2, tint: Self.hex(0xffd88a))
    private lazy var CELL = Self.pbr(Self.cellTexture(), metal: 0.6, rough: 0.15, doubleSided: true)
    private let GLS = SatelliteRig.pbr(SatelliteRig.hex(0x04070b), metal: 0.4, rough: 0.03)
    private let LENS2: SCNMaterial = {
        let m = SatelliteRig.pbr(SatelliteRig.hex(0x1a2a44), metal: 0.8, rough: 0.05)
        m.transparency = 0.85
        return m
    }()
    private let RED = SatelliteRig.flat(SatelliteRig.hex(0xff3b3b)), GRN = SatelliteRig.flat(SatelliteRig.hex(0x3bff7a))
    private let WHL = SatelliteRig.flat(.white)
    private let CAB = SatelliteRig.pbr(SatelliteRig.hex(0x2a2f38), metal: 0, rough: 0.7)

    override init() {
        super.init()
        BLU.emission.contents = Self.blue
        BLU.emission.intensity = 2.2
        build()
    }

    func setInputs(state: Assistant.State, deepIdle: Bool, privacy: Bool) {
        let m: Mode
        switch state {
        case .listening: m = .listening
        case .transcribing, .thinking, .acting, .booting: m = .thinking
        case .speaking: m = .speaking
        case .idle, .error: m = .idle
        }
        let color: NSColor
        if privacy { color = NSColor(HUD.privacy) }
        else if case .error = state { color = NSColor(HUD.amber) }
        else { color = Self.blue }
        lock.lock(); mode = m; accent = color; lock.unlock()
    }

    // MARK: - Animation (the preview's loop(), "close-up" mode)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = CGFloat(min(0.2, max(0, time - (last ?? time))))
        last = time
        lock.lock(); let S = self.mode, accent = self.accent; lock.unlock()
        if appliedAccent != accent {
            appliedAccent = accent
            BLU.diffuse.contents = accent
            BLU.emission.contents = accent
        }
        let t = CGFloat(time)
        /// The preview eases by a fixed fraction per 60 fps frame: the same speed at any frame rate.
        func L(_ key: String, _ v: CGFloat, _ a: CGFloat = 0.1) -> CGFloat {
            guard let c = cur[key] else { cur[key] = v; return v }
            let n = c + (v - c) * (1 - pow(1 - a, dt * 60))
            cur[key] = n
            return n
        }
        // Voice level: real while speaking, fixed like the preview otherwise.
        let raw = CGFloat(min(1, max(0, (levels?.voice ?? 0) * 1.8)))
        voice += (raw - voice) * (1 - exp(-dt * 18))
        let lv: CGFloat = S == .speaking ? voice : S == .listening ? 0.5 : S == .thinking ? 0.3 : 0.1
        let think = S == .thinking, listen = S == .listening, speak = S == .speaking
        let facing = listen || speak

        // While waiting everything moves at about half the preview speed: calmer and smooth at 20 fps.
        root.position = SCNVector3(0, sin(t * (facing ? 1.1 : 0.5)) * 0.03, 0)
        sat.eulerAngles = SCNVector3(L("rx", facing ? 0.1 : sin(t * 0.22) * 0.18, 0.05),
                                     L("ry", facing ? 0 : sin(t * 0.15) * 1.3, 0.05),
                                     L("rz", facing ? 0 : sin(t * 0.13) * 0.12, 0.05))
        let open: CGFloat = listen ? 1 : think ? 0.8 : speak ? 0.92 : 0.6
        for (i, w) in wings.enumerated() {
            let o = L("o\(i)", open, 0.06)
            for (k, pg) in w.panels.enumerated() where k > 0 {
                pg.eulerAngles.y = w.d * (1 - o) * 2.6 * (k % 2 == 1 ? 1 : -1)
            }
            w.arm.eulerAngles.x = L("ax\(i)", think ? sin(t * 1.5) * 0.35 : listen ? -0.25 : 0, 0.05)
            w.p1.eulerAngles.y = w.d * (1 - o) * 0.4
            let phase = t * 1.3 + CGFloat(i) * 0.5
            w.tg.scale = Self.uniform(Int(floor(phase)) % 2 == 1 && phase.truncatingRemainder(dividingBy: 1) < 0.3 ? 0.05 : 0)
        }
        ring.eulerAngles.z += dt * (think ? 3 : speak ? 1 + lv * 2 : listen ? 0.35 : 0.15)
        ring.eulerAngles.x = L("rgx", think ? sin(t * 1.3) * 0.3 : facing ? 0 : 0.3, 0.05)
        ring.eulerAngles.y = L("rgy", think ? cos(t * 1.1) * 0.2 : 0, 0.05)
        ring2.eulerAngles.z -= dt * (think ? 2 : listen || speak ? 0.2 : 0.09)
        ring2.eulerAngles.x = L("r2x", think ? cos(t * 0.9) * 0.3 : facing ? 0 : -0.28, 0.05)
        ring2.eulerAngles.y = L("r2y", think ? sin(t * 1.4) * 0.2 : 0.15, 0.05)
        let step12 = Int(floor(t * 12))
        for (i, s) in segs.enumerated() {
            s.isHidden = !(think ? (i + step12) % 4 == 0 : speak ? CGFloat(i) / 16 < lv + 0.2 : true)
        }
        let ap: CGFloat = listen ? 1.35 : speak ? 0.9 + lv * 0.6 : think ? 0.7 : 1
        let blink = t.truncatingRemainder(dividingBy: 4.6) < 0.13
        iris.scale = SCNVector3(ap, 1, blink ? 0.1 : ap)
        iris2.scale = Self.uniform(blink ? 0.1 : ap)
        for (i, b) in blades.enumerated() {
            let a = CGFloat(i) / 8 * .pi * 2 + t * (think ? 2 : 0.1)
            let r = 0.034 + (1 - ap) * 0.012
            b.position = SCNVector3(cos(a) * r, sin(a) * r, 0.022)
            b.eulerAngles.z = a + .pi / 2 + 0.4
        }
        let ix = L("ix", think ? sin(t * 2) * 0.012 : 0), iy = L("iy", think ? 0.006 : 0)
        iris.position.x = ix; iris.position.y = iy
        iris2.position.x = ix; iris2.position.y = iy
        irisG.scale = Self.uniform(0.12 + lv * 0.12 + (listen ? 0.06 : 0))
        for (i, b) in brows.enumerated() {
            b.eulerAngles.z = L("bw\(i)", (i == 1 ? 1 : -1) * (listen ? -0.05 : think ? 0.3 : 0.15), 0.1)
            b.position.y = L("by\(i)", listen ? 0.085 : 0.078, 0.1)
        }
        let step8 = Int(floor(t * 8))
        for (i, m) in mouth.enumerated() {
            m.scale.y = speak ? 0.5 + lv * 3.5 * abs(sin(t * 11 + CGFloat(i) * 0.9)) : 1
            m.isHidden = think && (i + step8) % 9 >= 3
        }
        dsh.eulerAngles.x = L("dx", listen ? -0.7 : think ? sin(t * 1.5) * 0.5 : -0.2, 0.05)
        dish.eulerAngles.y += dt * (think ? 2.5 : listen || speak ? 0.4 : 0.18)
        ftip.scale = Self.uniform(think ? 1 + 0.6 * abs(sin(t * 8)) : 1)
        for (i, g) in trackers.enumerated() {
            g.eulerAngles.y = L("tk\(i)", (i == 1 ? 1 : -1) * 0.4 + (think ? sin(t * 2 + CGFloat(i)) * 0.4 : 0), 0.05)
        }
        ledG.scale = Self.uniform(Int(floor(t * 1.5)) % 2 == 1 ? 0.05 : 0)
        strobeG.scale = Self.uniform(t.truncatingRemainder(dividingBy: 2.2) < 0.08 ? 0.12 : 0)
        for g in thrusters {
            if random.next() < 0.008 * dt * 60 { g.scale = Self.uniform(0.09) }
            else { g.scale = Self.uniform(g.scale.x * pow(0.88, dt * 60)) }
        }
        engG.scale = Self.uniform(0.08 + lv * 0.08 + (think ? 0.04 * sin(t * 6) : 0))
        BLU.emission.intensity = L("ei", listen ? 3 : speak ? 1.6 + lv * 2 : 2.2, 0.15)
        particleGroup.isHidden = !think
        if think {
            for i in particles.indices {
                particles[i].a += dt * particles[i].s * 2
                let p = particles[i]
                p.node.position = SCNVector3(cos(p.a) * p.r, p.y + sin(p.a * 2) * 0.02, sin(p.a) * p.r)
            }
        }
        for (i, w) in waves.enumerated() {
            let kk = (t * 0.9 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
            w.scale = Self.uniform(0.6 + kk * (listen ? 1.4 : 2.2))
            w.position.z = 0.17 + (listen ? 0.3 - kk * 0.3 : kk * 0.25)
            w.opacity = facing ? (1 - kk) * 0.55 : 0
        }
    }

    // MARK: - Construction (same order and numbers as the preview)

    private func build() {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.environment()
        scene.lightingEnvironment.intensity = 1.6
        let camera = SCNCamera()
        // The angle is measured across the width: the low window only crops the empty space above and below.
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 30
        camera.zNear = 0.02
        camera.zFar = 60
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.03, 2.45)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight(); ambient.type = .ambient; ambient.color = Self.hex(0xcfe0ff); ambient.intensity = 250
        let key = SCNLight(); key.type = .directional; key.color = Self.hex(0xfff6ea); key.intensity = 1800
        let rim = SCNLight(); rim.type = .directional; rim.color = Self.hex(0x6cc8ff); rim.intensity = 1400
        for (light, pos) in [(ambient, SCNVector3(0, 1, 0)), (key, SCNVector3(3, 5, 6)), (rim, SCNVector3(-4, 2, -5))] {
            let n = SCNNode(); n.light = light; n.position = pos
            n.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(n)
        }

        scene.rootNode.addChildNode(root)
        root.addChildNode(sat)
        let RX = SCNVector3(CGFloat.pi / 2, 0, .pi / 8)
        let half = CGFloat.pi / 2

        // Hull, gold foil, bands, front collar and rear taper.
        mk(cy(0.1, 0.1, 0.2), HULL, sat, rot: RX)
        mk(cy(0.103, 0.103, 0.07), FOIL, sat, SCNVector3(0, 0, -0.04), rot: RX)
        for z: CGFloat in [-0.075, -0.005, 0.075] { mk(cy(0.104, 0.104, 0.006), TI2, sat, SCNVector3(0, 0, z), rot: RX) }
        mk(cy(0.085, 0.1, 0.04), TI2, sat, SCNVector3(0, 0, 0.12), rot: RX)
        mk(cy(0.1, 0.07, 0.05), TI, sat, SCNVector3(0, 0, -0.125), rot: RX)
        mk(cy(0.07, 0.05, 0.03), DK, sat, SCNVector3(0, 0, -0.16), rot: RX)
        for i in 0..<8 {
            let a = CGFloat(i) / 8 * .pi * 2 + .pi / 8, ca = cos(a), sa = sin(a)
            mk(box(0.003, 0.003, 0.16), BLU, sat, SCNVector3(ca * 0.101, sa * 0.101, 0))
            if i % 2 == 1 {
                mk(box(0.03, 0.02, 0.012), TI, sat, SCNVector3(ca * 0.104, sa * 0.104, 0.04), rot: SCNVector3(0, 0, a))
            } else {
                mk(box(0.026, 0.014, 0.03), DK, sat, SCNVector3(ca * 0.104, sa * 0.104, -0.03), rot: SCNVector3(0, 0, a))
                for k in 0..<3 {
                    mk(box(0.022, 0.002, 0.004), TI2, sat, SCNVector3(ca * 0.112, sa * 0.112, -0.042 + CGFloat(k) * 0.012), rot: SCNVector3(0, 0, a))
                }
            }
        }
        for i in 0..<4 {
            let a = CGFloat(i) / 4 * .pi * 2 + 0.4
            let c = grp(sat, SCNVector3(cos(a) * 0.1, sin(a) * 0.1, -0.06), rot: SCNVector3(0, 0, a))
            mk(box(0.01, 0.006, 0.11), CAB, c, SCNVector3(0.006, 0, 0.02))
        }

        // Eye.
        let eye = grp(sat, SCNVector3(0, 0, 0.145))
        mk(cy(0.066, 0.074, 0.035, 48), DK, eye, rot: SCNVector3(half, 0, 0))
        torus(0.064, 0.007, 64, TI2, eye, SCNVector3(0, 0, 0.018))
        torus(0.054, 0.003, 64, TI, eye, SCNVector3(0, 0, 0.02))
        for i in 0..<24 {
            let a = CGFloat(i) / 24 * .pi * 2
            mk(box(0.004, 0.008, 0.006), TI, eye, SCNVector3(cos(a) * 0.07, sin(a) * 0.07, 0.008), rot: SCNVector3(0, 0, a))
        }
        mk(cy(0.05, 0.05, 0.01, 48), GLS, eye, SCNVector3(0, 0, 0.018), rot: SCNVector3(half, 0, 0))
        for _ in 0..<8 { blades.append(mk(box(0.03, 0.012, 0.002), DK, eye, SCNVector3(0, 0, 0.022))) }
        iris = mk(cy(0.022, 0.022, 0.004, 40), BLU, eye, SCNVector3(0, 0, 0.023), rot: SCNVector3(half, 0, 0))
        iris2 = torus(0.014, 0.0015, 40, Self.flat(Self.hex(0xcff2ff)), eye, SCNVector3(0, 0, 0.026))
        mk(sphereCap(0.05, .pi / 5, 40, 16), LENS2, eye, SCNVector3(0, 0, -0.02), rot: SCNVector3(half, 0, 0))
        irisG = glow(eye, 0.16, SCNVector3(0, 0, 0.045))
        mk(sphere(0.005), WHL, eye, SCNVector3(-0.016, 0.016, 0.03))
        mk(sphere(0.0025), WHL, eye, SCNVector3(0.012, -0.01, 0.03))
        for d: CGFloat in [-1, 1] {
            brows.append(mk(box(0.05, 0.006, 0.008), TI2, sat, SCNVector3(d * 0.035, 0.078, 0.135), rot: SCNVector3(0, 0, d * -0.15)))
        }
        for i in 0..<9 { mouth.append(mk(box(0.006, 0.01, 0.004), BLU, sat, SCNVector3(-0.032 + CGFloat(i) * 0.008, -0.087, 0.128))) }
        mk(box(0.08, 0.018, 0.004), DK, sat, SCNVector3(0, -0.087, 0.126))

        // Gyroscopic rings.
        ring = grp(sat, SCNVector3(0, 0, 0.08))
        torus(0.21, 0.009, 128, TI2, ring)
        torus(0.198, 0.003, 128, DK, ring)
        for i in 0..<16 {
            let a = CGFloat(i) / 16 * .pi * 2
            segs.append(mk(box(0.026, 0.005, 0.005), BLU, ring, SCNVector3(cos(a) * 0.21, sin(a) * 0.21, 0.01), rot: SCNVector3(0, 0, a + .pi / 2)))
        }
        for i in 0..<4 {
            let a = CGFloat(i) / 4 * .pi * 2 + .pi / 4
            mk(box(0.005, 0.09, 0.005), TI, ring, SCNVector3(cos(a) * 0.155, sin(a) * 0.155, 0), rot: SCNVector3(0, 0, a + .pi / 2))
            mk(box(0.016, 0.016, 0.016), TI, ring, SCNVector3(cos(a) * 0.21, sin(a) * 0.21, 0), rot: SCNVector3(0, 0, a))
        }
        ring2 = grp(sat, SCNVector3(0, 0, 0.09))
        torus(0.235, 0.004, 128, TI, ring2)
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * .pi * 2
            mk(sphere(0.006), BLU, ring2, SCNVector3(cos(a) * 0.235, sin(a) * 0.235, 0))
        }

        // Solar wings.
        let back = Self.pbr(Self.hex(0xe8e8e2), metal: 0, rough: 0.6)
        for d: CGFloat in [-1, 1] {
            let arm = grp(sat, SCNVector3(d * 0.105, 0, -0.02))
            mk(cy(0.009, 0.009, 0.13, 12), TI, arm, SCNVector3(d * 0.065, 0, 0), rot: SCNVector3(0, 0, half))
            mk(cy(0.014, 0.014, 0.025, 16), TI2, arm, SCNVector3(d * 0.02, 0, 0), rot: SCNVector3(0, 0, half))
            mk(sphere(0.018), TI2, arm, SCNVector3(d * 0.13, 0, 0))
            mk(box(0.05, 0.004, 0.004), CAB, arm, SCNVector3(d * 0.07, 0.012, 0))
            let p1 = grp(arm, SCNVector3(d * 0.135, 0, 0))
            var panels: [SCNNode] = []
            var par = p1
            for k in 0..<3 {
                let pg = grp(par, k > 0 ? SCNVector3(d * 0.122, 0, 0) : SCNVector3Zero)
                let pl = grp(pg, SCNVector3(d * 0.061, 0, 0))
                mk(box(0.118, 0.15, 0.004), TI, pl)
                mk(box(0.11, 0.142, 0.005), CELL, pl)
                mk(box(0.118, 0.004, 0.008), TI2, pl, SCNVector3(0, 0.075, 0))
                mk(box(0.118, 0.004, 0.008), TI2, pl, SCNVector3(0, -0.075, 0))
                for yy: CGFloat in [-0.05, 0.05] {
                    mk(cy(0.003, 0.003, 0.008, 8), TI2, pl, SCNVector3(d * -0.059, yy, 0), rot: SCNVector3(0, 0, half))
                }
                mk(box(0.112, 0.144, 0.002), back, pl, SCNVector3(0, 0, -0.004))
                panels.append(pg)
                par = pg
            }
            mk(sphere(0.006), d > 0 ? GRN : RED, par, SCNVector3(d * 0.125, 0.08, 0))
            let tg = glow(par, 0, SCNVector3(d * 0.125, 0.08, 0), Self.hex(d > 0 ? 0x3bff7a : 0xff3b3b))
            wings.append((arm, p1, panels, d, tg))
        }

        // Dish.
        dish = grp(sat, SCNVector3(0, 0.105, -0.04))
        mk(cy(0.012, 0.016, 0.012, 16), TI2, dish)
        mk(cy(0.006, 0.006, 0.06, 10), TI, dish, SCNVector3(0, 0.035, 0))
        dsh = grp(dish, SCNVector3(0, 0.07, 0))
        let dishMat = Self.pbr(Self.hex(0xeef1f4), metal: 0.5, rough: 0.3, doubleSided: true)
        mk(sphereCap(0.058, .pi / 3.2, 40, 10), dishMat, dsh, scale: SCNVector3(1, 0.5, 1), rot: SCNVector3(CGFloat.pi, 0, 0))
        torus(0.05, 0.003, 64, TI, dsh, SCNVector3(0, -0.02, 0), rot: SCNVector3(half, 0, 0))
        for i in 0..<3 {
            let a = CGFloat(i) / 3 * .pi * 2
            let from = SIMD3<Float>(Float(cos(a) * 0.022), -0.03, Float(sin(a) * 0.022))
            let s = mk(cy(0.0015, 0.0015, 0.05, 6), TI, dsh, SCNVector3(from))
            let dir = simd_normalize(SIMD3<Float>(0, -0.05, 0) - from)
            s.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
        }
        mk(cy(0.008, 0.004, 0.012, 12), DK, dsh, SCNVector3(0, -0.052, 0))
        ftip = mk(sphere(0.005), BLU, dsh, SCNVector3(0, -0.06, 0))

        // Star trackers, boom with red LED, whip antenna.
        for d: CGFloat in [-1, 1] {
            let g = grp(sat, SCNVector3(d * 0.06, 0.085, -0.08), rot: SCNVector3(-0.5, d * 0.4, 0))
            mk(cy(0.012, 0.012, 0.03, 16), DK, g, SCNVector3(0, 0.015, 0))
            mk(cy(0.016, 0.012, 0.01, 16), TI2, g, SCNVector3(0, 0.034, 0))
            mk(cy(0.009, 0.009, 0.002, 16), GLS, g, SCNVector3(0, 0.04, 0))
            trackers.append(g)
        }
        let boom = grp(sat, SCNVector3(0.045, -0.1, -0.06))
        mk(cy(0.003, 0.003, 0.14, 6), TI, boom, SCNVector3(0, -0.07, 0))
        for i in 0..<4 { mk(box(0.012, 0.002, 0.002), TI, boom, SCNVector3(0, -0.03 - CGFloat(i) * 0.03, 0)) }
        mk(sphere(0.006), RED, boom, SCNVector3(0, -0.145, 0))
        ledG = glow(boom, 0, SCNVector3(0, -0.145, 0), Self.hex(0xff4040))
        let whip = grp(sat, SCNVector3(-0.05, -0.095, -0.09), rot: SCNVector3(0.3, 0, 0.3))
        mk(cy(0.0015, 0.0015, 0.18, 6), TI2, whip, SCNVector3(0, -0.09, 0))

        // RCS thruster clusters.
        for (x, y): (CGFloat, CGFloat) in [(0.074, 0.074), (-0.074, 0.074), (0.074, -0.074), (-0.074, -0.074)] {
            let n = grp(sat, SCNVector3(x, y, -0.1))
            mk(box(0.03, 0.03, 0.02), TI, n)
            for (dx, dy, rx, ry): (CGFloat, CGFloat, CGFloat, CGFloat) in [(0.018, 0, 0, half), (0, 0.018, half, 0), (0, 0, 0, 0)] {
                let side = dx != 0 || dy != 0
                mk(cy(0.004, 0.007, 0.012, 10), DK, n,
                   SCNVector3(dx * (x > 0 ? 1 : -1), dy * (y > 0 ? 1 : -1), side ? 0 : -0.014),
                   rot: SCNVector3(rx != 0 ? rx : (side ? 0 : half), 0, ry != 0 ? (x > 0 ? -1 : 1) * half : 0))
            }
            thrusters.append(glow(n, 0, SCNVector3(0, 0, -0.03), Self.hex(0xbfe8ff)))
        }

        // Engine and strobe.
        let eng = grp(sat, SCNVector3(0, 0, -0.18))
        mk(cy(0.03, 0.045, 0.04, 24), TI2, eng, rot: SCNVector3(half, 0, 0))
        mk(cy(0.026, 0.026, 0.004, 24), BLU, eng, SCNVector3(0, 0, -0.02), rot: SCNVector3(half, 0, 0))
        engG = glow(eng, 0.1, SCNVector3(0, 0, -0.03))
        mk(sphere(0.005), WHL, sat, SCNVector3(0, 0.09, 0.05))
        strobeG = glow(sat, 0, SCNVector3(0, 0.09, 0.05), .white)

        // Particles (thinking) and signal waves.
        sat.addChildNode(particleGroup)
        let dot = SCNSphere(radius: 0.0035); dot.segmentCount = 6; dot.firstMaterial = BLU
        for _ in 0..<60 {
            let n = SCNNode(geometry: dot)
            particleGroup.addChildNode(n)
            particles.append((n, random.next() * 6.28, 0.27 + random.next() * 0.1, (random.next() - 0.5) * 0.12, 0.5 + random.next()))
        }
        particleGroup.isHidden = true
        for _ in 0..<3 {
            let m = Self.flat(Self.hex(0x7fd6ff))
            m.blendMode = .add
            m.writesToDepthBuffer = false
            let w = torus(0.1, 0.003, 64, m, sat, SCNVector3(0, 0, 0.17))
            w.opacity = 0
            waves.append(w)
        }

        // Extra detail (11 November, "more beautiful and detailed", same style). All of it is static:
        // it is merged with the rest, so it adds no draw calls.
        func strut(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r: CGFloat, _ m: SCNMaterial, _ p: SCNNode) {
            let n = mk(cy(r, r, CGFloat(simd_distance(a, b)), 6), m, p, SCNVector3((a + b) / 2))
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
        }
        // Gold propellant tanks around the rear taper, each with two straps and a feed line.
        for i in 0..<4 {
            let a = CGFloat(i) / 4 * .pi * 2, x = cos(a) * 0.083, y = sin(a) * 0.083
            mk(sphere(0.023), FOIL, sat, SCNVector3(x, y, -0.137))
            torus(0.0236, 0.0014, 24, TI2, sat, SCNVector3(x, y, -0.137))
            torus(0.0236, 0.0014, 24, TI2, sat, SCNVector3(x, y, -0.137), rot: SCNVector3(half, 0, a))
            strut(SIMD3(Float(x), Float(y), -0.137), SIMD3(Float(cos(a) * 0.04), Float(sin(a) * 0.04), -0.172), 0.0018, CAB, sat)
        }
        // Engine: stiffening rings on the bell, gimbal struts and four vernier nozzles.
        torus(0.0465, 0.0022, 40, TI, sat, SCNVector3(0, 0, -0.2))
        torus(0.039, 0.0016, 40, DK, sat, SCNVector3(0, 0, -0.19))
        torus(0.033, 0.0016, 40, TI2, sat, SCNVector3(0, 0, -0.178))
        for i in 0..<4 {
            let a = CGFloat(i) / 4 * .pi * 2 + .pi / 4, ca = Float(cos(a)), sa = Float(sin(a))
            strut(SIMD3(ca * 0.052, sa * 0.052, -0.15), SIMD3(ca * 0.036, sa * 0.036, -0.186), 0.002, TI2, sat)
            mk(cy(0.0035, 0.0075, 0.014, 10), DK, sat, SCNVector3(CGFloat(ca) * 0.06, CGFloat(sa) * 0.06, -0.168), rot: SCNVector3(half, 0, 0))
            mk(cy(0.0028, 0.0028, 0.002, 10), BLU, sat, SCNVector3(CGFloat(ca) * 0.06, CGFloat(sa) * 0.06, -0.1745), rot: SCNVector3(half, 0, 0))
        }
        // Wings: a truss yoke on each arm, radiator fins, ribs behind the panels and a thin light along their edge.
        for w in wings {
            let d = Float(w.d)
            for s: Float in [-1, 1] {
                strut(SIMD3(d * 0.03, 0, 0), SIMD3(d * 0.132, s * 0.062, 0), 0.0022, TI, w.arm)
                strut(SIMD3(d * 0.075, s * 0.027, 0), SIMD3(d * 0.105, 0, 0), 0.0015, TI2, w.arm)
            }
            mk(box(0.004, 0.13, 0.004), TI2, w.arm, SCNVector3(w.d * 0.132, 0, 0))
            for k in 0..<5 {
                mk(box(0.0015, 0.034, 0.03), DK, w.arm, SCNVector3(w.d * (0.036 + CGFloat(k) * 0.005), 0, 0))
            }
            for pg in w.panels {
                mk(box(0.112, 0.0016, 0.0016), BLU, pg, SCNVector3(w.d * 0.061, 0.0712, 0.0045))
                mk(box(0.112, 0.0016, 0.0016), BLU, pg, SCNVector3(w.d * 0.061, -0.0712, 0.0045))
                for off: CGFloat in [-0.03, 0.03] {
                    mk(box(0.003, 0.14, 0.004), TI, pg, SCNVector3(w.d * (0.061 + off), 0, -0.0065))
                }
                mk(box(0.11, 0.003, 0.004), TI, pg, SCNVector3(w.d * 0.061, 0, -0.0065))
                mk(cy(0.0045, 0.0045, 0.03, 10), TI2, pg, SCNVector3(0, 0, 0))
            }
        }
        // A small second dish under the hull, looking forward and down.
        let dish2 = grp(sat, SCNVector3(0, -0.098, -0.005), rot: SCNVector3(CGFloat.pi - 0.75, 0, 0))
        mk(cy(0.008, 0.011, 0.008, 12), TI2, dish2)
        mk(cy(0.004, 0.004, 0.034, 8), TI, dish2, SCNVector3(0, 0.02, 0))
        let bowl = grp(dish2, SCNVector3(0, 0.046, 0))
        mk(sphereCap(0.036, .pi / 3.2, 28, 8), Self.pbr(Self.hex(0xeef1f4), metal: 0.5, rough: 0.3, doubleSided: true), bowl,
           scale: SCNVector3(1, 0.5, 1), rot: SCNVector3(CGFloat.pi, 0, 0))
        torus(0.031, 0.002, 40, TI, bowl, SCNVector3(0, -0.0125, 0), rot: SCNVector3(half, 0, 0))
        mk(cy(0.001, 0.001, 0.03, 6), TI, bowl, SCNVector3(0, -0.02, 0))
        mk(sphere(0.0035), BLU, bowl, SCNVector3(0, -0.036, 0))
        // Helical antenna on top.
        let helix = grp(sat, SCNVector3(-0.047, 0.088, 0.02), rot: SCNVector3(0, 0, 0.25))
        mk(cy(0.007, 0.009, 0.006, 12), TI2, helix)
        mk(cy(0.0012, 0.0012, 0.062, 6), TI, helix, SCNVector3(0, 0.031, 0))
        for k in 0..<7 {
            torus(0.0075 - CGFloat(k) * 0.0005, 0.0009, 20, TI2, helix, SCNVector3(0, 0.012 + CGFloat(k) * 0.0075, 0), rot: SCNVector3(half, 0, 0))
        }
        mk(sphere(0.0028), BLU, helix, SCNVector3(0, 0.064, 0))
        // A crown of small lights around the eye, and fine marks on its housing.
        for i in 0..<16 {
            let a = CGFloat(i) / 16 * .pi * 2 + .pi / 16
            mk(sphere(0.0022), BLU, eye, SCNVector3(cos(a) * 0.0745, sin(a) * 0.0745, 0.019))
        }
        for i in 0..<48 where i % 2 == 0 {
            let a = CGFloat(i) / 48 * .pi * 2
            mk(box(0.0012, 0.005, 0.002), TI2, eye, SCNVector3(cos(a) * 0.0585, sin(a) * 0.0585, 0.0235), rot: SCNVector3(0, 0, a + half))
        }
        // Rings: a thin line of light behind the main ring, markers on the outer one.
        torus(0.21, 0.0016, 128, BLU, ring, SCNVector3(0, 0, -0.011))
        for i in 0..<32 {
            let a = CGFloat(i) / 32 * .pi * 2
            mk(box(0.002, 0.007, 0.011), i % 4 == 0 ? TI2 : DK, ring, SCNVector3(cos(a) * 0.221, sin(a) * 0.221, 0), rot: SCNVector3(0, 0, a + half))
        }
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * .pi * 2 + .pi / 6
            mk(box(0.012, 0.007, 0.007), TI2, ring2, SCNVector3(cos(a) * 0.235, sin(a) * 0.235, 0), rot: SCNVector3(0, 0, a + half))
        }
        mergeStaticParts()
    }

    /// Fewer draw calls for the fanless Air: every group of parts that never moves on its own
    /// becomes one flattened node; the animated nodes (and the glow sprites) stay separate.
    private func mergeStaticParts() {
        var moving: [SCNNode] = [root, sat, ring, ring2, iris, iris2, irisG, dish, dsh, ftip, ledG, strobeG, engG, particleGroup]
        moving += segs + blades + brows + mouth + trackers + thrusters + waves
        for w in wings { moving += [w.arm, w.p1, w.tg] + w.panels }
        let ids = Set(moving.map(ObjectIdentifier.init))
        func hasMoving(_ n: SCNNode) -> Bool {
            ids.contains(ObjectIdentifier(n)) || n.childNodes.contains(where: hasMoving)
        }
        func merge(_ n: SCNNode) {
            let still = n.childNodes.filter { !hasMoving($0) }
            if still.count > 1 {
                let group = SCNNode()
                still.forEach { $0.removeFromParentNode(); group.addChildNode($0) }
                n.addChildNode(group.flattenedClone())
            }
            n.childNodes.filter(hasMoving).forEach(merge)
        }
        merge(root)
    }

    // MARK: - Helpers mirroring the preview's mk / grp / glow

    @discardableResult
    private func mk(_ g: SCNGeometry, _ m: SCNMaterial, _ p: SCNNode, _ pos: SCNVector3? = nil,
                    scale: SCNVector3? = nil, rot: SCNVector3? = nil) -> SCNNode {
        let geo = g.copy() as! SCNGeometry
        geo.materials = [m]
        let n = SCNNode(geometry: geo)
        if let pos { n.position = pos }
        if let scale { n.scale = scale }
        if let rot { n.eulerAngles = rot }
        p.addChildNode(n)
        return n
    }

    private func grp(_ p: SCNNode, _ pos: SCNVector3? = nil, rot: SCNVector3? = nil) -> SCNNode {
        let n = SCNNode()
        if let pos { n.position = pos }
        if let rot { n.eulerAngles = rot }
        p.addChildNode(n)
        return n
    }

    /// three.js tori lie in the XY plane, SceneKit's in XZ: an inner node turns it.
    @discardableResult
    private func torus(_ r: CGFloat, _ tube: CGFloat, _ n: Int, _ m: SCNMaterial, _ p: SCNNode,
                       _ pos: SCNVector3? = nil, rot: SCNVector3? = nil) -> SCNNode {
        let outer = grp(p, pos, rot: rot)
        let g = SCNTorus(ringRadius: r, pipeRadius: tube)
        g.ringSegmentCount = n
        g.pipeSegmentCount = 10
        mk(g, m, outer, rot: SCNVector3(CGFloat.pi / 2, 0, 0))
        return outer
    }

    /// Additive soft sprite, like THREE.Sprite with the radial texture.
    private func glow(_ p: SCNNode, _ s: CGFloat, _ pos: SCNVector3, _ color: NSColor = SatelliteRig.hex(0x7fd6ff)) -> SCNNode {
        let plane = SCNPlane(width: 1, height: 1)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = glowTexture
        m.multiply.contents = color
        m.blendMode = .add
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.position = pos
        n.scale = Self.uniform(s)
        n.constraints = [SCNBillboardConstraint()]
        n.renderingOrder = 20
        p.addChildNode(n)
        return n
    }

    private static func uniform(_ s: CGFloat) -> SCNVector3 { SCNVector3(s, s, s) }

    private func box(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNGeometry {
        SCNBox(width: x, height: y, length: z, chamferRadius: 0)
    }

    private func sphere(_ r: CGFloat) -> SCNGeometry {
        let s = SCNSphere(radius: r)
        s.segmentCount = 16
        return s
    }

    /// Same vertices, smooth normals and UVs as THREE.CylinderGeometry (y axis, first vertex towards +z).
    private func cy(_ top: CGFloat, _ bottom: CGFloat, _ h: CGFloat, _ n: Int = 8) -> SCNGeometry {
        var pos: [SCNVector3] = [], nor: [SCNVector3] = [], uv: [CGPoint] = [], idx: [UInt16] = []
        let slope = (bottom - top) / h
        for row in 0...1 {
            let y = row == 0 ? h / 2 : -h / 2, r = row == 0 ? top : bottom
            for i in 0...n {
                let th = CGFloat(i) / CGFloat(n) * .pi * 2
                pos.append(SCNVector3(r * sin(th), y, r * cos(th)))
                let len = sqrt(1 + slope * slope)
                nor.append(SCNVector3(sin(th) / len, slope / len, cos(th) / len))
                uv.append(CGPoint(x: CGFloat(i) / CGFloat(n), y: CGFloat(row)))
            }
        }
        for i in 0..<n {
            let a = UInt16(i), b = UInt16(i + n + 1), c = UInt16(i + n + 2), d = UInt16(i + 1)
            idx += [a, b, d, b, c, d]
        }
        for (y, r, up) in [(h / 2, top, true), (-h / 2, bottom, false)] where r > 0 {
            let center = UInt16(pos.count)
            pos.append(SCNVector3(0, y, 0)); nor.append(SCNVector3(0, up ? 1 : -1, 0)); uv.append(CGPoint(x: 0.5, y: 0.5))
            for i in 0...n {
                let th = CGFloat(i) / CGFloat(n) * .pi * 2
                pos.append(SCNVector3(r * sin(th), y, r * cos(th)))
                nor.append(SCNVector3(0, up ? 1 : -1, 0))
                uv.append(CGPoint(x: 0.5 + sin(th) * 0.5, y: 0.5 + cos(th) * 0.5))
            }
            for i in 0..<n {
                let a = center + 1 + UInt16(i), b = a + 1
                idx += up ? [center, a, b] : [center, b, a]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor),
                                     SCNGeometrySource(textureCoordinates: uv)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    /// Top cap of a sphere (THREE.SphereGeometry with thetaLength < π).
    private func sphereCap(_ r: CGFloat, _ thetaLength: CGFloat, _ w: Int, _ h: Int) -> SCNGeometry {
        var pos: [SCNVector3] = [], nor: [SCNVector3] = [], uv: [CGPoint] = [], idx: [UInt16] = []
        for iy in 0...h {
            let v = CGFloat(iy) / CGFloat(h), theta = v * thetaLength
            for ix in 0...w {
                let u = CGFloat(ix) / CGFloat(w), phi = u * .pi * 2
                let p = SCNVector3(-cos(phi) * sin(theta), cos(theta), sin(phi) * sin(theta))
                pos.append(SCNVector3(p.x * r, p.y * r, p.z * r)); nor.append(p); uv.append(CGPoint(x: u, y: v))
            }
        }
        for iy in 0..<h {
            for ix in 0..<w {
                let a = UInt16(iy * (w + 1) + ix + 1), b = UInt16(iy * (w + 1) + ix)
                let c = UInt16((iy + 1) * (w + 1) + ix), d = UInt16((iy + 1) * (w + 1) + ix + 1)
                if iy > 0 { idx += [a, b, d] }
                idx += [b, c, d]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor),
                                     SCNGeometrySource(textureCoordinates: uv)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    // MARK: - Materials and textures

    private static func pbr(_ contents: Any, metal: CGFloat, rough: CGFloat, repeatU: CGFloat = 1,
                            doubleSided: Bool = false, tint: NSColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = contents
        if let tint { m.multiply.contents = tint }
        m.metalness.contents = metal
        m.roughness.contents = rough
        m.isDoubleSided = doubleSided
        if repeatU != 1 {
            m.diffuse.wrapS = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(repeatU, 1, 1)
        }
        return m
    }

    private static func flat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }

    /// Draws like a 2D canvas; `brighten` reproduces three.js r128 reading canvas textures as linear.
    private static func image(_ w: Int, _ h: Int, brighten: Bool = true, _ draw: (CGContext) -> Void) -> NSImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Canvas coordinates: origin at the top left.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        if brighten, let data = ctx.data {
            let table = (0..<256).map { UInt8(min(255, pow(Double($0) / 255, 1 / 2.2) * 255)) }
            let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            for i in 0..<(w * h) { for c in 0..<3 { px[i * 4 + c] = table[Int(px[i * 4 + c])] } }
        }
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: h))
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    private static func hexTexture() -> NSImage {
        var g = SatelliteRandom(seed: 3)
        return image(256, 256) { x in
            x.setFillColor(rgb(0x8a, 0x92, 0x9e)); x.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let r: CGFloat = 18
            for j in -1..<10 {
                for i in -1..<10 {
                    let cx = CGFloat(i) * r * 1.73 + (j % 2 != 0 ? r * 0.866 : 0), cy = CGFloat(j) * r * 1.5
                    let path = CGMutablePath()
                    for k in 0..<6 {
                        let a = CGFloat(k) / 6 * .pi * 2 + .pi / 6
                        let p = CGPoint(x: cx + cos(a) * r * 0.95, y: cy + sin(a) * r * 0.95)
                        k == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    path.closeSubpath()
                    let v = 125 + g.next() * 30
                    x.setFillColor(rgb(v, v + 6, v + 14)); x.addPath(path); x.fillPath()
                    x.setStrokeColor(rgb(30, 35, 45, 0.7)); x.setLineWidth(1.5); x.addPath(path); x.strokePath()
                    x.setFillColor(rgb(30, 35, 45, 0.6)); x.fillEllipse(in: CGRect(x: cx - 1.4, y: cy - 1.4, width: 2.8, height: 2.8))
                }
            }
        }
    }

    private static func foilTexture() -> NSImage {
        var g = SatelliteRandom(seed: 11)
        return image(256, 256) { x in
            x.setFillColor(rgb(0xb8, 0x86, 0x2e)); x.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            for _ in 0..<260 {
                let px = g.next() * 256, py = g.next() * 256
                let light = g.next() < 0.5
                x.setStrokeColor(light ? rgb(255, 230, 160, 0.25 + g.next() * 0.3) : rgb(90, 60, 10, 0.25 + g.next() * 0.3))
                x.setLineWidth(1 + g.next() * 2)
                x.move(to: CGPoint(x: px, y: py))
                x.addLine(to: CGPoint(x: px + (g.next() - 0.5) * 50, y: py + (g.next() - 0.5) * 30))
                x.strokePath()
            }
        }
    }

    private static func cellTexture() -> NSImage {
        var g = SatelliteRandom(seed: 17)
        return image(128, 256) { x in
            x.setFillColor(rgb(0x0a, 0x16, 0x30)); x.fill(CGRect(x: 0, y: 0, width: 128, height: 256))
            for j in 0..<16 {
                for i in 0..<8 {
                    let v = 20 + g.next() * 12
                    x.setFillColor(rgb(v, v + 30, v + 80)); x.fill(CGRect(x: i * 16 + 1, y: j * 16 + 1, width: 14, height: 14))
                    x.setFillColor(rgb(140, 190, 255, 0.25)); x.fill(CGRect(x: i * 16 + 2, y: j * 16 + 7, width: 12, height: 1))
                }
            }
            x.setStrokeColor(rgb(200, 215, 230, 0.6)); x.setLineWidth(2); x.stroke(CGRect(x: 1, y: 1, width: 126, height: 254))
        }
    }

    private static func radialTexture() -> NSImage {
        image(64, 64, brighten: false) { x in
            let colors = [rgb(255, 255, 255, 1), rgb(255, 255, 255, 0.45), rgb(255, 255, 255, 0)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.25, 1])!
            x.drawRadialGradient(gradient, startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                                 endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
        }
    }

    /// The preview's studio: dark room (#121822) with five soft light panels, as an equirectangular image.
    private static func environment() -> NSImage {
        let w = 512, h = 256
        return image(w, h, brighten: false) { x in
            x.setFillColor(rgb(0x12, 0x18, 0x22)); x.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let panels: [(size: CGFloat, color: (CGFloat, CGFloat, CGFloat), dir: SIMD3<Double>)] = [
                (12, (4.2, 4.1, 4), [1, 10, 3]), (3, (2.2, 2.3, 2.5), [-10, 3, 4]), (3, (0.5, 1.4, 3), [10, 2, -3]),
                (8, (1.3, 1.4, 1.6), [0, 2, 12]), (10, (0.3, 0.6, 1.4), [0, -9, 0]),
            ]
            for p in panels {
                let d = simd_normalize(p.dir), dist = simd_length(p.dir)
                let u = (atan2(d.x, -d.z) / (2 * .pi) + 0.5) * Double(w), v = acos(d.y) / .pi * Double(h)
                let radius = CGFloat(atan(Double(p.size) / 2 / dist) / .pi) * CGFloat(h) * 1.2
                let c = p.color, k: CGFloat = 255 / 2.2
                let colors = [rgb(min(255, c.0 * k), min(255, c.1 * k), min(255, c.2 * k), 1),
                              rgb(min(255, c.0 * k), min(255, c.1 * k), min(255, c.2 * k), 0)] as CFArray
                let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0.3, 1])!
                for shift in [-Double(w), 0, Double(w)] {
                    let center = CGPoint(x: u + shift, y: v)
                    x.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
                }
            }
        }
    }
}

/// Small deterministic generator: the textures look the same at every launch.
private struct SatelliteRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
}
