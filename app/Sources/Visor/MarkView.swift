import AppKit
import SceneKit
import SwiftUI

/// The mark, live. A trefoil tube built in code and rendered by SceneKit
/// on the GPU: the icon's knot in iridescent metal, lit by a studio
/// environment so it catches light as it turns. Any size, sixty frames a
/// second, no sprite sheet and none of its seams.
///
/// Two motions. The turn: a slow spin in the knot's own plane with a
/// gentle tilt, six seconds a revolution. The formation: three strands
/// fly in from beyond the frame, twist into place and settle with a small
/// overshoot; the closed knot takes over from exactly that pose.
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
        private var arcs: [SCNNode] { (0..<3).compactMap { rig?.childNode(withName: "arc\($0)", recursively: false) } }

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
                let t = (CACurrentMediaTime() - start) / 6.0
                node.eulerAngles = SCNVector3(
                    MarkScene.rad(14 + 8 * sin(2 * .pi * t)),
                    MarkScene.rad(6 * cos(2 * .pi * t)),
                    CGFloat(2 * .pi * t))
            }
            rig.runAction(turn, forKey: "turn")
        }

        /// The formation, from `date`. The knot hides, the three strands
        /// start out beyond the frame and come home; then the knot returns
        /// and the turn resumes from its rest pose.
        func form(at date: Date) {
            guard let rig, let knot, arcs.count == 3, !Design.Motion.reduced else { return }
            formedAt = date
            rig.removeAction(forKey: "turn")
            knot.isHidden = true
            let total: Double = 2.5
            let arcDuration: Double = 1.6
            for (k, arc) in arcs.enumerated() {
                arc.isHidden = false
                let home = arc.position
                let out = MarkScene.outward[k]
                let delay = Double(k) * 0.2
                arc.position = SCNVector3(home.x + out.x, home.y + out.y, home.z + out.z)
                arc.eulerAngles = SCNVector3(0, 0, MarkScene.rad(50))
                arc.opacity = 0
                let fly = SCNAction.customAction(duration: arcDuration) { node, elapsed in
                    let u = Double(elapsed) / arcDuration
                    let e = MarkScene.backOut(u)
                    node.position = SCNVector3(home.x + out.x * CGFloat(1 - e),
                                               home.y + out.y * CGFloat(1 - e),
                                               home.z + out.z * CGFloat(1 - e))
                    node.eulerAngles = SCNVector3(0, 0, MarkScene.rad(50 * (1 - e)))
                    node.opacity = CGFloat(min(1, u * 4))
                }
                arc.runAction(.sequence([.wait(duration: delay), fly]))
            }
            // The whole rig settles into its rest tilt as the strands arrive.
            rig.eulerAngles = SCNVector3(MarkScene.rad(24), MarkScene.rad(-2), MarkScene.rad(-25))
            let settle = SCNAction.customAction(duration: total) { node, elapsed in
                let u = MarkScene.smooth(max(0, Double(elapsed) - 0.4) / (total - 0.4))
                node.eulerAngles = SCNVector3(MarkScene.rad(14 + 10 * (1 - u)),
                                              MarkScene.rad(6 - 8 * (1 - u)),
                                              MarkScene.rad(-25 * (1 - u)))
            }
            rig.runAction(.sequence([settle, .run { [weak self] _ in
                DispatchQueue.main.async {
                    knot.isHidden = false
                    self?.arcs.forEach { $0.isHidden = true }
                    self?.startTurn()
                }
            }]), forKey: "turn")
        }
    }
}

/// The knot's scene: geometry, material, lights, camera.
enum MarkScene {
    static let restPose = SCNVector3(rad(14), rad(6), 0)
    static let scale: CGFloat = 0.62
    static let tube: CGFloat = 0.115
    /// Where each strand starts, relative to its home: outward along its own
    /// centroid, far enough to begin beyond the frame.
    static var outward: [SCNVector3] = []

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

        let knot = SCNNode(geometry: tube(from: 0, to: 2 * .pi, segments: 240, closed: true))
        knot.name = "knot"; knot.geometry?.materials = [material]
        rig.addChildNode(knot)

        outward = []
        for k in 0..<3 {
            let a = 2 * Double.pi * Double(k) / 3, b = 2 * Double.pi * Double(k + 1) / 3
            var centroid = SCNVector3Zero
            let n = 48
            for i in 0...n {
                let p = point(a + (b - a) * Double(i) / Double(n))
                centroid = SCNVector3(centroid.x + p.x, centroid.y + p.y, centroid.z + p.z)
            }
            centroid = SCNVector3(centroid.x / CGFloat(n + 1), centroid.y / CGFloat(n + 1), centroid.z / CGFloat(n + 1))
            let arc = SCNNode(geometry: tube(from: a, to: b, segments: 80, closed: false, origin: centroid))
            arc.name = "arc\(k)"; arc.geometry?.materials = [material]
            arc.position = centroid
            arc.isHidden = true
            rig.addChildNode(arc)
            let len = sqrt(centroid.x * centroid.x + centroid.y * centroid.y)
            outward.append(SCNVector3(centroid.x / len * 3.2, centroid.y / len * 3.2, 0))
        }

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

        let camera = SCNCamera(); camera.fieldOfView = 34; camera.zNear = 1; camera.zFar = 50
        camera.wantsHDR = true; camera.bloomIntensity = 0.35; camera.bloomThreshold = 0.75; camera.bloomBlurRadius = 12
        let cam = SCNNode(); cam.camera = camera; cam.position = SCNVector3(0, 0, 11.5)
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
    static func tube(from a: Double, to b: Double, segments: Int, closed: Bool, origin: SCNVector3 = SCNVector3Zero) -> SCNGeometry {
        let ring = 14
        var verts: [SCNVector3] = [], norms: [SCNVector3] = [], uvs: [CGPoint] = []
        var indices: [Int32] = []
        let count = closed ? segments : segments + 1
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
                verts.append(SCNVector3(p.x + nx * tube - origin.x, p.y + ny * tube - origin.y, p.z + nz * tube - origin.z))
                norms.append(SCNVector3(nx, ny, nz))
                uvs.append(CGPoint(x: CGFloat(t) / (2 * .pi) * 3, y: CGFloat(j) / CGFloat(ring)))
            }
        }
        let rings = closed ? segments : segments
        for i in 0..<rings {
            let i1 = closed ? (i + 1) % segments : i + 1
            for j in 0..<ring {
                let j1 = (j + 1) % ring
                let a0 = Int32(i * ring + j), a1 = Int32(i * ring + j1)
                let b0 = Int32(i1 * ring + j), b1 = Int32(i1 * ring + j1)
                indices += [a0, b0, a1, a1, b0, b1]
            }
        }
        var sources = [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms),
                       SCNGeometrySource(textureCoordinates: uvs)]
        var elements = [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        if !closed {
            // Caps: a fan at each end.
            for (ringIndex, flip) in [(0, true), (count - 1, false)] {
                let centreIndex = Int32(verts.count)
                let t = ringIndex == 0 ? a : b
                let p = point(t)
                verts.append(SCNVector3(p.x - origin.x, p.y - origin.y, p.z - origin.z))
                let p1 = point(t + 0.001)
                var n = SCNVector3(p1.x - p.x, p1.y - p.y, p1.z - p.z)
                let nl = sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
                n = SCNVector3(n.x / nl * (flip ? -1 : 1), n.y / nl * (flip ? -1 : 1), n.z / nl * (flip ? -1 : 1))
                norms.append(n); uvs.append(CGPoint(x: 0, y: 0.5))
                var cap: [Int32] = []
                for j in 0..<ring {
                    let j1 = (j + 1) % ring
                    let v0 = Int32(ringIndex * ring + j), v1 = Int32(ringIndex * ring + j1)
                    cap += flip ? [centreIndex, v1, v0] : [centreIndex, v0, v1]
                }
                elements.append(SCNGeometryElement(indices: cap, primitiveType: .triangles))
            }
            sources = [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms),
                       SCNGeometrySource(textureCoordinates: uvs)]
        }
        return SCNGeometry(sources: sources, elements: elements)
    }

    /// A still of the knot at its rest pose, for the Design Lab.
    @MainActor
    static func snapshot(size: CGFloat) -> NSImage? {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = make()
        renderer.pointOfView = renderer.scene?.rootNode.childNodes.first { $0.camera != nil }
        return renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
    }
}
