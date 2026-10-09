import SwiftUI
import SceneKit

enum Mood: Equatable {
    case sleeping  // nothing has happened for a while
    case idle      // awake, nothing going on
    case working   // agents busy
    case finished  // something finished, unseen
    case needsYou  // blocked on a permission prompt or question

    /// Accent for badges, buttons, and the pet's glow.
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .sleeping: NSColor(calibratedRed: 0.66, green: 0.64, blue: 0.80, alpha: 1)
        case .idle: NSColor(calibratedRed: 0.70, green: 0.72, blue: 1.00, alpha: 1)
        case .working: NSColor(calibratedRed: 0.36, green: 0.86, blue: 0.52, alpha: 1)
        case .finished: NSColor(calibratedRed: 0.42, green: 0.90, blue: 0.62, alpha: 1)
        case .needsYou: NSColor(calibratedRed: 1.00, green: 0.50, blue: 0.38, alpha: 1)
        }
    }
}

/// Mochi colors.
enum Skin: String, Codable, CaseIterable {
    case peach, strawberry, matcha, taro, lemon, soda

    var label: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .peach: NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.62, alpha: 1)
        case .strawberry: NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.76, alpha: 1)
        case .matcha: NSColor(calibratedRed: 0.72, green: 0.88, blue: 0.62, alpha: 1)
        case .taro: NSColor(calibratedRed: 0.80, green: 0.74, blue: 0.96, alpha: 1)
        case .lemon: NSColor(calibratedRed: 1.00, green: 0.92, blue: 0.62, alpha: 1)
        case .soda: NSColor(calibratedRed: 0.66, green: 0.86, blue: 1.00, alpha: 1)
        }
    }
}

/// Everything the pet needs to draw itself for one moment.
struct PetState {
    var skin: Skin = .peach
    var mood: Mood = .idle
    var look: CGSize = .zero        // -1...1, where the cursor is relative to the pet
    var escalation = 0
    var sad = false                 // agents have been blocked on you too long
    var celebratedAt = Date.distantPast
    var ateAt = Date.distantPast
    var pettedAt = Date.distantPast
    var pokedAt = Date.distantPast
}

/// The pet: a squishy 3D mochi with a tiny kawaii face, rendered with SceneKit.
/// It breathes, blinks, winks, glances around, follows your cursor, jiggles when poked or petted,
/// munches treats, hops when something finishes, and bounces with a "!" when it needs you.
struct PetView: View {
    let state: PetState
    var detailed = true   // emotes (z, !, sparkles, hearts) only when there's room
    var fps = 30          // lower while it sits in the notch, to save battery
    var paused = false    // screen off or locked: stop rendering entirely

    var body: some View {
        ZStack {
            PetSceneView(state: state, fps: fps, paused: paused)
            if detailed && !paused { PetEmotes(state: state).allowsHitTesting(false) }
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Your pet")
    }
}

// MARK: SceneKit view

private struct PetSceneView: NSViewRepresentable {
    let state: PetState
    let fps: Int
    let paused: Bool

    func makeCoordinator() -> PetScene { PetScene() }

    func makeNSView(context: Context) -> SCNView {
        let view = PassthroughSCNView(frame: .zero, options: nil)
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.delegate = context.coordinator
        apply(to: view)
        context.coordinator.update(state)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        apply(to: view)
        context.coordinator.update(state)
    }

    private func apply(to view: SCNView) {
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
        if view.rendersContinuously == paused { view.rendersContinuously = !paused }
        if view.isPlaying == paused { view.isPlaying = !paused }
    }
}

/// Lets clicks, hovers and scrolls fall through to SwiftUI.
private final class PassthroughSCNView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Builds the mochi and animates it every frame on SceneKit's render thread.
final class PetScene: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    let scene = SCNScene()
    let camera = SCNNode()

    private let root = SCNNode()      // hops and bounces
    private let jelly = SCNNode()     // squash, stretch, wobble
    private let face = SCNNode()      // turns toward the cursor
    private let skinMaterial = SCNMaterial()
    private let glowLight = SCNLight()

    // Face parts, each a container shown or hidden via opacity
    private var openEyes: [SCNNode] = []      // ● ●
    private var eyeBalls: [SCNNode] = []      // inside openEyes, scaled to blink
    private var winkEyes: [SCNNode] = []      // > <
    private var happyEyes: [SCNNode] = []     // ^ ^
    private var sleepEyes: [SCNNode] = []     // - -
    private var mouths: [String: SCNNode] = [:]

    private let lock = NSLock()
    private var state = PetState()
    private var appliedSkin: Skin?
    private var appliedMood: Mood?
    private var turn = SIMD2<Float>(0, 0)
    private var squish: Double = 0, squishVelocity: Double = 0
    private var lastTime: TimeInterval?
    private var lastPoke = Date.distantPast, lastPet = Date.distantPast, lastHop = Date.distantPast

    override init() {
        super.init()
        build()
    }

    func update(_ newState: PetState) {
        lock.lock()
        state = newState
        lock.unlock()
        if appliedSkin != newState.skin || appliedMood != newState.mood {
            let animated = appliedSkin != nil
            appliedSkin = newState.skin
            appliedMood = newState.mood
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.6 : 0
            skinMaterial.diffuse.contents = newState.skin.nsColor
            skinMaterial.emission.contents = newState.skin.nsColor.blended(withFraction: 0.5, of: .black)?.withAlphaComponent(0.25)
            glowLight.color = newState.mood.nsColor
            glowLight.intensity = newState.mood == .working || newState.mood == .needsYou || newState.mood == .finished ? 650 : 250
            SCNTransaction.commit()
        }
    }

    // MARK: Build

    private func build() {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 0.9

        let cam = SCNCamera()
        cam.fieldOfView = 24
        camera.camera = cam
        camera.position = SCNVector3(0, 0.05, 6.6)
        scene.rootNode.addChildNode(camera)

        addLight(.directional, intensity: 600, angles: SCNVector3(-0.75, 0.55, 0))  // key, upper right like the reference
        addLight(.directional, intensity: 160, angles: SCNVector3(-0.1, -0.9, 0))
        addLight(.ambient, intensity: 90, angles: SCNVector3(0, 0, 0))
        glowLight.type = .directional  // rim light from behind, tinted by mood
        let glow = SCNNode()
        glow.light = glowLight
        glow.eulerAngles = SCNVector3(0.2, .pi, 0)
        scene.rootNode.addChildNode(glow)

        scene.rootNode.addChildNode(root)
        root.addChildNode(jelly)
        jelly.addChildNode(face)

        // The mochi: soft, slightly squat, with a satin sheen
        skinMaterial.lightingModel = .physicallyBased
        skinMaterial.roughness.contents = 0.42
        skinMaterial.clearCoat.contents = 0.45
        skinMaterial.clearCoatRoughness.contents = 0.25
        let ball = SCNSphere(radius: 1)
        ball.segmentCount = 96
        ball.firstMaterial = skinMaterial
        let body = SCNNode(geometry: ball)
        body.scale = SCNVector3(1.03, 0.96, 0.95)
        jelly.addChildNode(body)

        let ink = Self.flat(NSColor(calibratedWhite: 0.04, alpha: 1))
        let shine = Self.flat(.white)

        for side: CGFloat in [-1, 1] {
            let anchor = Self.surface(x: side * 0.36, y: 0.08)

            // ● eye with one highlight
            let open = SCNNode()
            open.position = anchor.position
            open.eulerAngles = anchor.angles
            let ballNode = SCNNode(geometry: { let g = SCNSphere(radius: 0.15); g.segmentCount = 32; g.firstMaterial = ink; return g }())
            ballNode.scale = SCNVector3(1, 1, 0.3)
            let glint = SCNNode(geometry: { let g = SCNSphere(radius: 0.045); g.firstMaterial = shine; return g }())
            glint.position = SCNVector3(0.055, 0.06, 0.16) // the eyeball is squashed in z, so this sits just on its surface
            ballNode.addChildNode(glint)
            open.addChildNode(ballNode)
            face.addChildNode(open)
            openEyes.append(open)
            eyeBalls.append(ballNode)

            // > <  (points toward the nose)
            let chevron = CGMutablePath()
            let dir: CGFloat = -side
            chevron.move(to: CGPoint(x: -dir * 0.08, y: 0.1))
            chevron.addLine(to: CGPoint(x: dir * 0.08, y: 0))
            chevron.addLine(to: CGPoint(x: -dir * 0.08, y: -0.1))
            winkEyes.append(feature(Self.stroke(chevron, width: 0.04, material: ink), at: anchor))

            happyEyes.append(feature(Self.stroke(Self.arc(width: 0.24, depth: -0.16), width: 0.045, material: ink), at: anchor))
            sleepEyes.append(feature(Self.stroke(Self.arc(width: 0.22, depth: 0.07), width: 0.04, material: ink), at: anchor))

            // Soft blush
            let blushAnchor = Self.surface(x: side * 0.6, y: -0.18)
            let plane = SCNPlane(width: 0.36, height: 0.2)
            plane.firstMaterial = Self.blushMaterial()
            let blush = SCNNode(geometry: plane)
            blush.position = blushAnchor.position
            blush.eulerAngles = blushAnchor.angles
            face.addChildNode(blush)
        }

        // Mouths. The reference's little open mouth: dark red rounded rect with an ink outline.
        let mouthAnchor = Self.surface(x: 0, y: -0.2)
        let o = SCNNode()
        let outline = SCNNode(geometry: Self.roundedRect(width: 0.085, height: 0.13, radius: 0.025, material: ink))
        let inside = SCNNode(geometry: Self.roundedRect(width: 0.05, height: 0.095, radius: 0.015,
                                                        material: Self.flat(NSColor(calibratedRed: 0.72, green: 0.13, blue: 0.16, alpha: 1))))
        inside.position.z = 0.012
        o.addChildNode(outline)
        o.addChildNode(inside)
        mouths["o"] = feature(o, at: mouthAnchor)
        mouths["smile"] = feature(Self.stroke(Self.arc(width: 0.16, depth: 0.08), width: 0.035, material: ink), at: mouthAnchor)
        mouths["frown"] = feature(Self.stroke(Self.arc(width: 0.15, depth: -0.06), width: 0.035, material: ink), at: mouthAnchor)
        mouths["flat"] = feature(Self.stroke(Self.arc(width: 0.09, depth: 0), width: 0.032, material: ink), at: mouthAnchor)
        let cat = SCNNode() // ω
        for side: CGFloat in [-1, 1] {
            let half = Self.stroke(Self.arc(width: 0.09, depth: 0.05), width: 0.03, material: ink)
            half.position.x = side * 0.045
            cat.addChildNode(half)
        }
        mouths["cat"] = feature(cat, at: mouthAnchor)
    }

    private func feature(_ node: SCNNode, at anchor: (position: SCNVector3, angles: SCNVector3)) -> SCNNode {
        let holder = SCNNode()
        holder.position = anchor.position
        holder.eulerAngles = anchor.angles
        holder.addChildNode(node)
        holder.opacity = 0
        face.addChildNode(holder)
        return holder
    }

    private func addLight(_ type: SCNLight.LightType, intensity: CGFloat, angles: SCNVector3) {
        let n = SCNNode()
        n.light = SCNLight()
        n.light!.type = type
        n.light!.intensity = intensity
        n.eulerAngles = angles
        scene.rootNode.addChildNode(n)
    }

    // MARK: Animate

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        let st = state
        lock.unlock()
        let t = time
        let dt = min(0.1, max(0.001, time - (lastTime ?? time - 1.0 / 30)))
        lastTime = time
        let now = Date()
        let mood = st.mood
        let sinceHop = now.timeIntervalSince(st.celebratedAt)
        let sincePet = now.timeIntervalSince(st.pettedAt)
        let sinceAte = now.timeIntervalSince(st.ateAt)

        // Jelly physics: a damped spring, kicked by pokes, pets, and landings.
        if st.pokedAt > lastPoke { lastPoke = st.pokedAt; squishVelocity += 3.2 }
        if st.pettedAt > lastPet { lastPet = st.pettedAt; squishVelocity -= 1.6 }
        if st.celebratedAt > lastHop { lastHop = st.celebratedAt }
        if sinceHop > 0.72 && sinceHop < 0.72 + dt * 1.5 { squishVelocity += 2.6 } // landing
        let breath = sin(t * (mood == .sleeping ? 1.1 : 2.1)) * 0.025
        let munch = sinceAte < 1.2 ? abs(sin(sinceAte * 14)) * 0.05 : 0
        let target = breath + munch
        let accel = -90 * (squish - target) - 7 * squishVelocity
        squishVelocity += accel * dt
        squish += squishVelocity * dt
        let s = CGFloat(max(-0.25, min(0.3, squish)))
        let grow: CGFloat = mood == .needsYou && st.escalation > 0 ? 1.07 : 1
        jelly.scale = SCNVector3(grow * (1 + s), grow * (1 - s), grow * (1 + s * 0.6))

        // Idle antics: every ~7 seconds, maybe do a little something.
        let window = floor(t / 7)
        let antic = Int(abs(sin(window * 12.9898) * 43758.5453)) % 7  // stable pseudo-random per window
        let anticPhase = t - window * 7
        let calm = mood == .idle || mood == .finished || (mood == .working && antic == 2)
        let doingAntic = calm && anticPhase < 1.3 && !st.sad

        // Bounce and hop
        var y: Double = 0
        switch mood {
        case .needsYou: y = abs(sin(t * (st.escalation > 1 ? 10 : 6.5))) * 0.14
        case .finished: y = max(0, sin(t * 2.2)) * 0.06
        case .sleeping: y = -0.03
        default: break
        }
        if doingAntic && antic == 4 { y += sin(min(1, anticPhase / 0.5) * .pi) * 0.18 } // little hop
        if sinceHop >= 0 && sinceHop < 0.72 { y += sin(sinceHop / 0.72 * .pi) * 0.6 }
        root.position.y = CGFloat(y)

        // Wobble: wiggle when petted or as an antic; sway while working
        var roll = 0.0
        if sincePet < 1.2 { roll = sin(sincePet * 18) * 0.14 * (1.2 - sincePet) }
        else if doingAntic && antic == 3 { roll = sin(anticPhase * 14) * 0.1 * (1.3 - anticPhase) }
        else if mood == .working { roll = sin(t * 2.2) * 0.04 }
        else if mood == .sleeping { roll = 0.12 + sin(t * 0.6) * 0.03 }
        jelly.eulerAngles.z = CGFloat(roll)

        // Face turns toward the cursor, reads while working, glances around as an antic
        var aim = SIMD2<Float>(Float(-st.look.height) * 0.28, Float(st.look.width) * 0.45)
        switch mood {
        case .working: aim = SIMD2(0.22, Float(sin(t * 1.1)) * 0.3)
        case .sleeping: aim = SIMD2(0.2, 0)
        default: if doingAntic && antic == 5 { aim = SIMD2(-0.05, Float(sin(anticPhase * 5)) * 0.45) }
        }
        if st.sad && mood != .needsYou { aim.x = 0.25 }
        turn += (aim - turn) * 0.12
        face.eulerAngles = SCNVector3(CGFloat(turn.x), CGFloat(turn.y), 0)

        // Expression
        let blinkPhase = t.truncatingRemainder(dividingBy: 4.1)
        let blinking = blinkPhase < 0.12 || (Int(t / 4.1) % 3 == 0 && blinkPhase > 0.28 && blinkPhase < 0.38)
        var eyes = "open", mouth = "smile"
        var winkSide: Int? = nil
        if sincePet < 1.6 { eyes = "wink"; mouth = "cat" }                  // > <  ω
        else if sinceAte < 1.4 { eyes = "happy"; mouth = "o" }              // ^ ^ munch
        else if st.sad && mood != .needsYou { eyes = "open"; mouth = "frown" }
        else {
            switch mood {
            case .sleeping: eyes = "sleep"; mouth = "flat"
            case .finished: eyes = "happy"; mouth = "cat"
            case .needsYou: eyes = "open"; mouth = "o"
            case .working: eyes = "open"; mouth = "flat"
            case .idle: eyes = "open"; mouth = "smile"
            }
            if doingAntic && (antic == 0 || antic == 1) { winkSide = antic; mouth = "o" } // the reference's wink
            if doingAntic && antic == 6 && mood == .idle && anticPhase < 1.0 { eyes = "sleep"; mouth = "o" } // yawn
        }

        for i in 0..<2 {
            let wink = eyes == "wink" || winkSide == i
            openEyes[i].opacity = eyes == "open" && !wink ? 1 : 0
            winkEyes[i].opacity = wink ? 1 : 0
            happyEyes[i].opacity = eyes == "happy" && !wink ? 1 : 0
            sleepEyes[i].opacity = eyes == "sleep" && !wink ? 1 : 0
            let open: CGFloat = mood == .needsYou ? 1.25 : 1
            let target: CGFloat = blinking ? 0.1 : open
            eyeBalls[i].scale.y += (target - eyeBalls[i].scale.y) * 0.45
            eyeBalls[i].scale.x = mood == .needsYou ? 1.15 : 1
        }
        for (name, node) in mouths { node.opacity = name == mouth ? 1 : 0 }
        if let o = mouths["o"] {
            let chew = sinceAte < 1.2 ? abs(sin(sinceAte * 14)) * 0.5 : 0
            let yawn = eyes == "sleep" && mood == .idle ? 0.6 : 0
            let alarm = mood == .needsYou ? abs(sin(t * 6)) * 0.25 : 0
            o.scale = SCNVector3(1, CGFloat(1 + chew + yawn + alarm), 1)
        }
    }

    // MARK: Geometry helpers

    /// A point on the mochi's front surface, with the rotation that makes a flat feature lie on it.
    private static func surface(x: CGFloat, y: CGFloat) -> (position: SCNVector3, angles: SCNVector3) {
        let sx: CGFloat = 1.03, sy: CGFloat = 0.96, sz: CGFloat = 0.95
        let nx = x / sx, ny = y / sy
        let nz = sqrt(max(0, 1 - nx * nx - ny * ny))
        let z = nz * sz + 0.005
        // Tilt the feature so it faces along the surface normal (up for y > 0, sideways for x).
        return (SCNVector3(x, y, z), SCNVector3(-asin(ny) * 0.9, asin(nx) * 0.9, 0))
    }

    private static func flat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }

    private static func blushMaterial() -> SCNMaterial {
        let size = NSSize(width: 64, height: 36)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.45, blue: 0.52, alpha: 0.7),
                            NSColor(calibratedRed: 1, green: 0.45, blue: 0.52, alpha: 0)])?
            .draw(in: NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)), relativeCenterPosition: .zero)
        image.unlockFocus()
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.isDoubleSided = false
        return m
    }

    /// A soft studio light probe: bright top, dark floor.
    private static func studioEnvironment() -> NSImage {
        let size = NSSize(width: 128, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.5, alpha: 1), NSColor(white: 0.12, alpha: 1)],
                   atLocations: [0, 0.45, 1], colorSpace: .genericRGB)?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }

    private static func arc(width: CGFloat, depth: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -width / 2, y: 0))
        p.addQuadCurve(to: CGPoint(x: width / 2, y: 0), control: CGPoint(x: 0, y: -depth * 2))
        return p
    }

    private static func roundedRect(width: CGFloat, height: CGFloat, radius: CGFloat, material: SCNMaterial) -> SCNGeometry {
        let path = NSBezierPath(roundedRect: NSRect(x: -width / 2, y: -height / 2, width: width, height: height), xRadius: radius, yRadius: radius)
        path.flatness = 0.002
        let shape = SCNShape(path: path, extrusionDepth: 0.01)
        shape.firstMaterial = material
        return shape
    }

    /// Extrudes a stroked 2D path into a thin 3D piece (eyes, mouths).
    private static func stroke(_ path: CGPath, width: CGFloat, material: SCNMaterial) -> SCNNode {
        let outline = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let bezier = NSBezierPath(cgPath: outline)
        bezier.flatness = 0.002 // the default is tuned for point-sized paths; ours are tiny, so curves came out straight
        let shape = SCNShape(path: bezier, extrusionDepth: 0.01)
        shape.firstMaterial = material
        return SCNNode(geometry: shape)
    }
}

// MARK: 2D emotes over the 3D pet

/// z's when asleep, a "!" when it needs you, sparkles when something finished, hearts when petted or fed.
private struct PetEmotes: View {
    let state: PetState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let sincePet = context.date.timeIntervalSince(state.pettedAt)
            let sinceAte = context.date.timeIntervalSince(state.ateAt)
            Canvas { g, size in
                let s = min(size.width, size.height)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)

                if sincePet < 2 || sinceAte < 1.6 {
                    let elapsed = min(sincePet, sinceAte)
                    for k in 0..<3 {
                        let phase = min(1, (elapsed - Double(k) * 0.18) / 1.4)
                        guard phase > 0 else { continue }
                        let x = c.x + CGFloat([-0.22, 0.05, 0.28][k]) * s + CGFloat(sin(phase * 6 + Double(k))) * s * 0.04
                        let p = CGPoint(x: x, y: c.y - s * 0.2 - CGFloat(phase) * s * 0.3)
                        g.draw(Text(Image(systemName: "heart.fill")).font(.system(size: s * 0.13 * CGFloat(0.8 + phase * 0.4)))
                            .foregroundColor(Color(red: 1, green: 0.45, blue: 0.6).opacity(1 - phase)), at: p)
                    }
                }

                switch state.mood {
                case .sleeping:
                    for k in 0..<3 {
                        let phase = (t * 0.45 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                        let p = CGPoint(x: c.x + s * 0.3 + CGFloat(phase) * s * 0.12, y: c.y - s * 0.22 - CGFloat(phase) * s * 0.22)
                        g.draw(Text("z").font(.system(size: s * 0.12 * CGFloat(0.7 + phase * 0.6), weight: .heavy, design: .rounded))
                            .foregroundColor(.white.opacity(0.8 * (1 - phase))), at: p)
                    }
                case .needsYou:
                    let pop = 1 + 0.15 * abs(sin(t * 6))
                    g.draw(Text("!").font(.system(size: s * 0.2 * CGFloat(pop), weight: .black, design: .rounded))
                        .foregroundColor(Mood.needsYou.color), at: CGPoint(x: c.x + s * 0.36, y: c.y - s * 0.3))
                case .finished:
                    let spots: [(Double, CGFloat)] = [(-2.4, 0.42), (-0.75, 0.44), (0.4, 0.42)]
                    for (k, spot) in spots.enumerated() {
                        let twinkle = 0.5 + 0.5 * abs(sin(t * 3 + Double(k) * 1.3))
                        let p = CGPoint(x: c.x + CGFloat(cos(spot.0)) * s * spot.1, y: c.y + CGFloat(sin(spot.0)) * s * spot.1)
                        g.draw(Text(Image(systemName: "sparkle"))
                            .font(.system(size: s * 0.11 * CGFloat(0.7 + 0.5 * twinkle)))
                            .foregroundColor(Color(red: 1, green: 0.9, blue: 0.5).opacity(twinkle)), at: p)
                    }
                default:
                    break
                }
            }
        }
    }
}

// MARK: Still images for the notch

/// Which still picture the notch shows: the pet as it normally looks, mid-blink, or mid-hop.
enum PetFrame: String, Sendable {
    case normal, blink, hop
}

/// The pet sitting in the notch is a still picture of the 3D pet, rendered once per look and cached,
/// so it costs nothing while it sits there. Only the open panel runs the live 3D pet.
final class PetImageCache: @unchecked Sendable {
    static let shared = PetImageCache()

    private let queue = DispatchQueue(label: "notchpet.petimages", qos: .utility)
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]
    private var pending = Set<String>()

    /// The cached picture for this look, or nil while it renders in the background (then `ready` runs on main).
    func image(for state: PetState, frame: PetFrame, ready: @escaping @Sendable () -> Void) -> NSImage? {
        let key = Self.key(state, frame)
        lock.lock()
        defer { lock.unlock() }
        if let image = images[key] { return image }
        if pending.insert(key).inserted {
            queue.async { [self] in
                let image = Self.render(state, frame)
                lock.lock()
                images[key] = image
                pending.remove(key)
                lock.unlock()
                DispatchQueue.main.async { ready() }
            }
        }
        return nil
    }

    /// Render every look for a skin ahead of time, so mood changes never wait on a render.
    func prewarm(skin: Skin) {
        for mood in [Mood.idle, .working, .finished, .needsYou, .sleeping] {
            for frame in [PetFrame.normal, .blink, .hop] {
                _ = image(for: PetState(skin: skin, mood: mood), frame: frame, ready: {})
            }
        }
    }

    private static func key(_ s: PetState, _ frame: PetFrame) -> String {
        "\(s.skin.rawValue)-\(s.mood)-\(s.sad)-\(s.escalation > 0)-\(frame.rawValue)"
    }

    /// Runs the 3D pet offscreen for a moment and keeps the last frame.
    private static func render(_ base: PetState, _ frame: PetFrame) -> NSImage {
        var state = base
        state.look = .zero
        state.pettedAt = .distantPast
        state.ateAt = .distantPast
        state.pokedAt = .distantPast
        // A hop is at its highest about a third of a second in.
        state.celebratedAt = frame == .hop ? Date().addingTimeInterval(-0.36) : .distantPast

        let pet = PetScene()
        pet.update(state)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = pet.scene
        renderer.pointOfView = pet.camera
        renderer.delegate = pet

        // Moments chosen to avoid the random idle antics (first 1.3s of every 7s); 20.6s lands mid-blink.
        let target: TimeInterval = frame == .blink ? 20.6 : 20.0
        var image = NSImage()
        for step in 0..<24 { // let the smoothing settle
            image = renderer.snapshot(atTime: target - Double(23 - step) / 30,
                                      with: CGSize(width: 128, height: 128), antialiasingMode: .multisampling4X)
        }
        return image
    }
}

/// The pet in the notch: a still picture that changes when its mood does (and blinks or hops now and then).
struct StaticPetView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let state = model.petState
        let cache = PetImageCache.shared
        let onReady: @Sendable () -> Void = { [model] in MainActor.assumeIsolated { model.petImagesVersion += 1 } }
        Group {
            if let image = cache.image(for: state, frame: model.earFrame, ready: onReady)
                ?? cache.image(for: state, frame: .normal, ready: onReady) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .id(model.petImagesVersion) // redraw once a missing picture has been rendered
        .accessibilityLabel("Your pet")
    }
}

// MARK: Snapshots (for checking the look without a screen)

/// `NotchPet --render-pet <dir>` writes one PNG per mood (plus a wink and a petted frame), and exits.
enum PetSnapshot {
    static func render(to dir: URL) {
        let now = Date()
        let shots: [(String, PetState)] = [
            ("sleeping", PetState(mood: .sleeping)),
            ("idle", PetState(mood: .idle, look: CGSize(width: 0.4, height: -0.2))),
            ("working", PetState(mood: .working)),
            ("finished", PetState(mood: .finished)),
            ("needsYou", PetState(mood: .needsYou)),
            ("petted", PetState(skin: .strawberry, mood: .idle, pettedAt: now.addingTimeInterval(0.5))),
            ("matcha", PetState(skin: .matcha, mood: .idle)),
        ]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, state) in shots {
            let pet = PetScene()
            pet.update(state)
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = pet.scene
            renderer.pointOfView = pet.camera
            renderer.delegate = pet
            var image = NSImage()
            for frame in 0..<40 { // let the smoothing settle; t=1.0+ avoids an antic window start
                image = renderer.snapshot(atTime: 2.0 + Double(frame) / 30, with: CGSize(width: 300, height: 300), antialiasingMode: .multisampling4X)
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
    }
}
