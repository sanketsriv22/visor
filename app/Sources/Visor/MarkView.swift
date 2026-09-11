import AppKit
import SceneKit
import SwiftUI

/// The mark, live. A trefoil tube built in code and rendered by SceneKit
/// on the GPU: the icon's knot in iridescent metal, lit by a studio
/// environment so it catches light as it turns. Any size, sixty frames a
/// second, no sprite sheet and none of its seams.
///
/// Two motions. The turn: the knot's plane wobbles on a cone about the
/// line of sight while it turns slowly in its own plane, so it reads as a
/// solid thing and never goes edge-on. The formation: the one tube draws
/// itself — three strands grow out from three points and meet — while
/// the rig eases from a tipped pose into the turn's.
struct HeroMark: View {
    var size: CGFloat
    var formedAt: Date? = nil

    var body: some View {
        MarkView(formedAt: formedAt)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct MarkView: NSViewRepresentable {
    var formedAt: Date?

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = MarkScene.make()
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isPlaying = !Design.Motion.reduced
        context.coordinator.view = view
        context.coordinator.startTurn()
        if let formedAt { context.coordinator.form(at: formedAt) }
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if let formedAt, context.coordinator.formedAt != formedAt {
            context.coordinator.form(at: formedAt)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: SCNView?
        var formedAt: Date?

        private var rig: SCNNode? { view?.scene?.rootNode.childNode(withName: "rig", recursively: false) }
        private var knot: SCNNode? { rig?.childNode(withName: "knot", recursively: false) }

        /// The rest turn: runs forever from the rig's rest pose.
        func startTurn() {
            guard let rig else { return }
            rig.removeAction(forKey: "turn")
            if Design.Motion.reduced {
                rig.eulerAngles = MarkScene.restPose
                return
            }
            let start = CACurrentMediaTime()
            let turn = SCNAction.customAction(duration: .infinity) { node, _ in
                node.eulerAngles = MarkScene.pose(at: CACurrentMediaTime() - start)
            }
            rig.runAction(turn, forKey: "turn")
        }

        /// The formation, from `date`. The knot is one tube throughout; it
        /// draws itself — three strands grow out from three points on the
        /// curve, both ways, and meet — so where they join is simply the
        /// geometry. The rig eases from a tipped pose into the turn's.
        func form(at date: Date) {
            guard let rig, let knot, let material = knot.geometry?.firstMaterial, !Design.Motion.reduced else { return }
            formedAt = date
            rig.removeAction(forKey: "turn")
            knot.isHidden = false
            knot.geometry = MarkScene.knot(grow: 0, material: material)
            let total: Double = 2.6
            var lastStep = -1
            let draw = SCNAction.customAction(duration: total) { node, elapsed in
                let u = Double(elapsed) / total
                // The strands draw over the first two seconds with an ease
                // that starts quick and lands soft.
                let g = MarkScene.smooth(min(1, u / 0.78))
                let step = Int(g * 240)
                if step != lastStep {
                    lastStep = step
                    node.geometry = MarkScene.knot(grow: g, material: material)
                }
            }
            let start = SCNVector3(MarkScene.rad(-34), MarkScene.rad(40), MarkScene.rad(-30))
            let end = MarkScene.pose(at: 0)
            let settle = SCNAction.customAction(duration: total) { node, elapsed in
                let u = MarkScene.smooth(Double(elapsed) / total)
                node.eulerAngles = SCNVector3(start.x + (end.x - start.x) * CGFloat(u),
                                              start.y + (end.y - start.y) * CGFloat(u),
                                              start.z + (end.z - start.z) * CGFloat(u))
            }
            knot.runAction(draw)
            rig.runAction(.sequence([settle, .run { [weak self] _ in
                DispatchQueue.main.async {
                    knot.geometry = MarkScene.knot(grow: 1, material: material)
                    self?.startTurn()
                }
            }]), forKey: "turn")
        }
    }
}

/// The knot's scene: geometry, material, lights, camera.
enum MarkScene {
    static let restPose = pose(at: 0)

    /// The knot's plane wobbles on a cone about the line of sight — every
    /// lobe comes toward you and falls away in turn, and it never goes
    /// edge-on — while it turns slowly in its own plane. Eight seconds
    /// round the cone, twenty for the turn.
    static func pose(at t: Double) -> SCNVector3 {
        let wobble = 2 * Double.pi * t / 8
        return SCNVector3(rad(22 * sin(wobble) + 8), rad(22 * cos(wobble)), CGFloat(2 * .pi * t / 20))
    }

    static let segments = 240
    static let ring = 14
    /// The tube's vertices, normals and texture coordinates, built once.
    static let sources: [SCNGeometrySource] = tubeSources(segments: segments)

    /// The knot, drawn `grow` of the way: 0 is nothing, 1 the whole tube.
    /// Three strands grow from three seeds — the thirds' boundaries —
    /// both ways along the curve until they meet in the middle of each
    /// third. Only the index buffer changes, so this is cheap enough to
    /// call every frame.
    static func knot(grow: Double, material: SCNMaterial) -> SCNGeometry {
        var indices: [Int32] = []
        for i in 0..<segments {
            let p = (Double(i) + 0.5) / Double(segments) * 3
            let within = p - floor(p)
            let fromSeed = min(within, 1 - within) * 2
            guard fromSeed <= grow else { continue }
            let i1 = i + 1
            for j in 0..<ring {
                let j1 = (j + 1) % ring
                let a0 = Int32(i * ring + j), a1 = Int32(i * ring + j1)
                let b0 = Int32(i1 * ring + j), b1 = Int32(i1 * ring + j1)
                indices += [a0, b0, a1, a1, b0, b1]
            }
        }
        if indices.isEmpty { indices = [0, 1, 2] }
        let g = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        g.materials = [material]
        return g
    }
    static let scale: CGFloat = 0.62
    static let tube: CGFloat = 0.115

    static func rad(_ deg: Double) -> CGFloat { CGFloat(deg * .pi / 180) }
    static func smooth(_ u: Double) -> Double { let x = min(1, max(0, u)); return x * x * (3 - 2 * x) }
    static func backOut(_ u: Double) -> Double {
        let x = min(1, max(0, u)); let c1 = 1.2, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    static func point(_ t: Double) -> SCNVector3 {
        SCNVector3(CGFloat(sin(t) + 2 * sin(2 * t)) * scale,
                   CGFloat(cos(t) - 2 * cos(2 * t)) * scale,
                   CGFloat(-sin(3 * t)) * scale)
    }

    static func make() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = nil
        let material = Self.material()

        let rig = SCNNode(); rig.name = "rig"
        rig.eulerAngles = restPose
        scene.rootNode.addChildNode(rig)

        let knot = SCNNode(geometry: Self.knot(grow: 1, material: material))
        knot.name = "knot"
        rig.addChildNode(knot)

        // A studio: an environment the metal reflects, a key, a rim, a kick.
        scene.lightingEnvironment.contents = studio()
        scene.lightingEnvironment.intensity = 2.2
        func light(_ name: String, _ pos: SCNVector3, _ color: NSColor, _ intensity: CGFloat) {
            let l = SCNLight(); l.type = .omni; l.color = color; l.intensity = intensity
            let n = SCNNode(); n.light = l; n.position = pos; n.name = name
            scene.rootNode.addChildNode(n)
        }
        light("key", SCNVector3(4, 3, 7), NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.95, alpha: 1), 900)
        light("rim", SCNVector3(-5, -2, 4), NSColor(calibratedRed: 0.6, green: 0.8, blue: 1.0, alpha: 1), 600)
        light("kick", SCNVector3(2, -5, 2), NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.9, alpha: 1), 400)

        let camera = SCNCamera(); camera.fieldOfView = 42; camera.zNear = 1; camera.zFar = 50
        camera.wantsHDR = true; camera.bloomIntensity = 0.35; camera.bloomThreshold = 0.75; camera.bloomBlurRadius = 12
        let cam = SCNNode(); cam.camera = camera; cam.position = SCNVector3(0, 0, 9.6)
        scene.rootNode.addChildNode(cam)
        return scene
    }

    /// Metal with a gradient that runs along the tube and shifts with the
    /// view angle: indigo, the accent, magenta, amber, cyan.
    static func material() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.metalness.contents = 1.0
        m.roughness.contents = 0.3
        m.diffuse.contents = gradient()
        // A little of its own colour, so the dark side of the tube still
        // reads as the palette and not as black wire.
        m.emission.contents = gradient()
        m.emission.intensity = 0.16
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.isDoubleSided = false
        m.shaderModifiers = [
            .fragment: """
            float facing = 1.0 - saturate(dot(normalize(_surface.view), _surface.normal));
            float f = pow(facing, 2.2);
            float3 edge = float3(0.62, 0.86, 1.0);
            _output.color.rgb = mix(_output.color.rgb, _output.color.rgb * edge * 1.6, f * 0.55);
            """
        ]
        return m
    }

    static func gradient() -> NSImage {
        let stops: [(CGFloat, NSColor)] = [
            (0.00, NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.52, alpha: 1)),
            (0.22, NSColor(calibratedRed: 0.58, green: 0.40, blue: 0.94, alpha: 1)),
            (0.45, NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.78, alpha: 1)),
            (0.66, NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.45, alpha: 1)),
            (0.84, NSColor(calibratedRed: 0.50, green: 0.86, blue: 1.00, alpha: 1)),
            (1.00, NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.52, alpha: 1)),
        ]
        let g = NSGradient(colors: stops.map(\.1), atLocations: stops.map(\.0), colorSpace: .deviceRGB)!
        let img = NSImage(size: NSSize(width: 512, height: 4))
        img.lockFocus()
        g.draw(in: NSRect(x: 0, y: 0, width: 512, height: 4), angle: 0)
        img.unlockFocus()
        return img
    }

    /// An equirectangular studio: dark floor, light ceiling, two soft
    /// boxes — the reflections that make metal read as metal.
    static func studio() -> NSImage {
        let w = 512, h = 256
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSGradient(colors: [NSColor(white: 0.03, alpha: 1), NSColor(white: 0.18, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.82, blue: 0.95, alpha: 1)],
                   atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)!
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)
        for (x, wd, a) in [(60, 120, 0.9), (300, 90, 0.7)] {
            let box = NSBezierPath(roundedRect: NSRect(x: x, y: 150, width: wd, height: 60), xRadius: 20, yRadius: 20)
            NSColor(white: 1, alpha: a).setFill(); box.fill()
        }
        let warm = NSBezierPath(ovalIn: NSRect(x: 400, y: 60, width: 80, height: 40))
        NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.85, alpha: 0.5).setFill(); warm.fill()
        img.unlockFocus()
        return img
    }

    /// A tube along the trefoil between two parameters: `segments` rings of
    /// twelve vertices, texture u along the length so the gradient runs
    /// along the tube. Optionally centred on `origin` so the node's pivot is
    /// its own centroid.
    static func tubeSources(segments: Int) -> [SCNGeometrySource] {
        let a = 0.0, b = 2 * Double.pi, closed = true
        let ring = Self.ring
        var verts: [SCNVector3] = [], norms: [SCNVector3] = [], uvs: [CGPoint] = []
        let count = segments + 1
        // Parallel-transport a frame along the curve so the tube doesn't
        // twist. Around a closed circuit the frame comes back rotated by
        // some angle; unwind that evenly along the way so the last ring
        // meets the first without a seam.
        var tangents: [SCNVector3] = [], normals: [SCNVector3] = []
        var prevNormal = SCNVector3(0, 0, 1)
        func frame(_ t: Double) -> (SCNVector3, SCNVector3) {
            let p = point(t), p1 = point(t + 0.001)
            var tangent = SCNVector3(p1.x - p.x, p1.y - p.y, p1.z - p.z)
            let tl = sqrt(tangent.x * tangent.x + tangent.y * tangent.y + tangent.z * tangent.z)
            tangent = SCNVector3(tangent.x / tl, tangent.y / tl, tangent.z / tl)
            var normal = prevNormal
            let dot = normal.x * tangent.x + normal.y * tangent.y + normal.z * tangent.z
            normal = SCNVector3(normal.x - tangent.x * dot, normal.y - tangent.y * dot, normal.z - tangent.z * dot)
            let nl = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
            normal = SCNVector3(normal.x / nl, normal.y / nl, normal.z / nl)
            prevNormal = normal
            return (tangent, normal)
        }
        for i in 0..<count {
            let (tg, nm) = frame(a + (b - a) * Double(i) / Double(segments))
            tangents.append(tg); normals.append(nm)
        }
        var unwind: Double = 0
        if closed {
            // One more step brings the frame back to the start; compare.
            let (tg, nm) = frame(a + (b - a))
            let n0 = normals[0]
            let bin = SCNVector3(tg.y * n0.z - tg.z * n0.y, tg.z * n0.x - tg.x * n0.z, tg.x * n0.y - tg.y * n0.x)
            let c = Double(nm.x * n0.x + nm.y * n0.y + nm.z * n0.z)
            let sn = Double(nm.x * bin.x + nm.y * bin.y + nm.z * bin.z)
            unwind = atan2(sn, c)
        }
        for i in 0..<count {
            let t = a + (b - a) * Double(i) / Double(segments)
            let p = point(t)
            let tangent = tangents[i]
            var normal = normals[i]
            var binormal = SCNVector3(tangent.y * normal.z - tangent.z * normal.y,
                                      tangent.z * normal.x - tangent.x * normal.z,
                                      tangent.x * normal.y - tangent.y * normal.x)
            if unwind != 0 {
                let phi = -unwind * Double(i) / Double(segments)
                let cp = CGFloat(cos(phi)), sp = CGFloat(sin(phi))
                let n2 = SCNVector3(normal.x * cp + binormal.x * sp, normal.y * cp + binormal.y * sp, normal.z * cp + binormal.z * sp)
                let b2 = SCNVector3(binormal.x * cp - normal.x * sp, binormal.y * cp - normal.y * sp, binormal.z * cp - normal.z * sp)
                normal = n2; binormal = b2
            }
            for j in 0..<ring {
                let ang = 2 * Double.pi * Double(j) / Double(ring)
                let nx = normal.x * CGFloat(cos(ang)) + binormal.x * CGFloat(sin(ang))
                let ny = normal.y * CGFloat(cos(ang)) + binormal.y * CGFloat(sin(ang))
                let nz = normal.z * CGFloat(cos(ang)) + binormal.z * CGFloat(sin(ang))
                verts.append(SCNVector3(p.x + nx * tube, p.y + ny * tube, p.z + nz * tube))
                norms.append(SCNVector3(nx, ny, nz))
                uvs.append(CGPoint(x: CGFloat(t) / (2 * .pi), y: CGFloat(j) / CGFloat(ring)))
            }
        }
        return [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms),
                SCNGeometrySource(textureCoordinates: uvs)]
    }

    /// A still of the knot at its rest pose, for the Design Lab.
    @MainActor
    static func snapshot(size: CGFloat, grow: Double = 1, at t: Double = 0) -> NSImage? {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        let scene = make()
        scene.rootNode.childNode(withName: "rig", recursively: false)?.eulerAngles = pose(at: t)
        if let knot = scene.rootNode.childNode(withName: "knot", recursively: true),
           let material = knot.geometry?.firstMaterial {
            knot.geometry = Self.knot(grow: grow, material: material)
        }
        renderer.scene = scene
        renderer.pointOfView = renderer.scene?.rootNode.childNodes.first { $0.camera != nil }
        return renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
    }
}
