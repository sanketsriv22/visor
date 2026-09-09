import AppKit
import SwiftUI

/// The takeover's picture: a scrim over the Mac, scanlines, a field of
/// pixels drifting into the notch, rough accent strokes drawn around the
/// real thing to do next, a guide with a speech bubble, a 3D mark on boot,
/// and a cheat sheet at the end.
///
/// Everything time-based is a pure function of the clock (TimelineView +
/// Canvas), so there is no per-frame state to fall behind, and Reduce
/// Motion turns the field and the sweep off.
struct TakeoverView: View {
    @ObservedObject var state: TakeoverState
    var onSkip: () -> Void
    var onAddAgent: () -> Void
    var onDone: () -> Void

    @State private var draw: CGFloat = 0
    @State private var bootPhase = 0   // 0 arriving, 1 settled, 2 flew into the notch

    private var reduced: Bool { Design.Motion.reduced }
    private var accent: Color { Design.Retro.accent }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let notch = view(state.geometry.notch)
            let origin = CGPoint(x: notch.midX, y: notch.maxY)

            let holes = holes(size: size)

            ZStack(alignment: .topLeading) {
                // The scrim, with the card and the notch cut out of it. The
                // cut is real transparency, which is what lets clicks fall
                // through this window to the controls underneath.
                Cutout(holes: holes)
                    .fill(Color.black.opacity(scrimOpacity), style: FillStyle(eoFill: true))
                    .animation(.easeInOut(duration: 0.4), value: state.step)

                if !reduced {
                    Group {
                        Scanlines()
                        if state.step == .boot { CRTSweep(start: state.stepStarted, height: size.height) }
                        PixelField(origin: origin, size: size, burstAt: state.lastBurst)
                    }
                    .mask(Cutout(holes: holes).fill(style: FillStyle(eoFill: true)))
                }

                annotations(size: size)

                switch state.step {
                case .boot:    boot(size: size, origin: origin)
                case .finale:  finale(size: size)
                default:       bubble(size: size)
                }

                skip
                    .position(x: size.width - 60, y: 44)
            }
            .frame(width: size.width, height: size.height)
            .onChange(of: state.step) { _ in
                draw = 0
                withAnimation(Design.Motion.animation(.easeOut(duration: 0.85))) { draw = 1 }
            }
            .onAppear {
                withAnimation(Design.Motion.animation(.easeOut(duration: 0.85))) { draw = 1 }
                // Rendered late (the lab): skip straight to the settled mark.
                if Date().timeIntervalSince(state.stepStarted) > 1.5 { bootPhase = 1 }
                let settle = reduced ? 0.1 : 0.35
                let fly = reduced ? 0.5 : 2.6
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    withAnimation(Design.Motion.animation(.easeOut(duration: 0.4))) { bootPhase = 1 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + fly) {
                    withAnimation(Design.Motion.animation(.spring(response: 0.7, dampingFraction: 0.82))) {
                        bootPhase = 2
                    }
                }
            }
        }
        .opacity(state.leaving ? 0 : 1)
        .accessibilityIdentifier("visor.takeover")
    }

    private var scrimOpacity: Double {
        if state.leaving { return 0 }
        return state.step == .boot ? 0.9 : 0.78
    }

    /// Where the scrim is not: the whole screen while the HUD is up, the
    /// card plus the notch while the card is open, the notch's click band
    /// otherwise.
    private func holes(size: CGSize) -> [CGRect] {
        let g = state.geometry
        if g.hud { return [CGRect(origin: .zero, size: size)] }
        let strip = notchRect.insetBy(dx: -6, dy: 0)
        let band = CGRect(x: strip.minX, y: strip.minY, width: strip.width, height: strip.height + 10)
        if g.expanded { return [card, band] }
        return [band]
    }

    // MARK: Coordinates

    /// AppKit rect (origin bottom-left) → SwiftUI rect (origin top-left).
    private func view(_ r: CGRect) -> CGRect {
        let b = state.geometry.bounds
        return CGRect(x: r.minX - b.minX, y: b.maxY - r.maxY, width: r.width, height: r.height)
    }

    private var card: CGRect { view(state.geometry.card) }
    private var notchRect: CGRect { view(state.geometry.notch) }
    private var switcher: CGRect { view(state.geometry.switcher) }
    private var notchH: CGFloat { notchRect.height }

    /// What each step points at, and where the bubble sits so it doesn't
    /// cover it.
    private struct Target {
        var ring: CGRect?
        var arrowTo: CGPoint?
        var bubble: CGPoint    // top-leading corner
    }

    private func target(size: CGSize) -> Target {
        let c = card
        let bw: CGFloat = 380
        let rightOfCard = CGPoint(x: min(c.maxX + 56, size.width - bw - 32), y: c.minY + notchH + 24)
        let leftOfCard = CGPoint(x: max(c.minX - bw - 56, 32), y: c.minY + notchH + 24)
        let below = CGPoint(x: size.width / 2 - bw / 2, y: c.maxY + 72)
        switch state.step {
        case .clickNotch, .summon:
            let ring = notchRect.insetBy(dx: -22, dy: -14)
            return Target(ring: ring, arrowTo: CGPoint(x: ring.midX, y: ring.maxY + 6),
                          bubble: CGPoint(x: size.width / 2 - bw / 2, y: notchRect.maxY + 150))
        case .addTask:
            let plus = CGRect(x: c.maxX - 62, y: c.minY + notchH + 8, width: 44, height: 44)
            return Target(ring: plus, arrowTo: CGPoint(x: plus.maxX + 6, y: plus.midY), bubble: rightOfCard)
        case .swapToChat:
            let ring = switcher.insetBy(dx: -10, dy: -6)
            return Target(ring: ring, arrowTo: CGPoint(x: ring.minX - 6, y: ring.midY),
                          bubble: CGPoint(x: leftOfCard.x, y: leftOfCard.y))
        case .ask:
            let composer = CGRect(x: c.minX + 10, y: c.maxY - 118, width: c.width - 20, height: 106)
            return Target(ring: composer, arrowTo: CGPoint(x: composer.maxX + 6, y: composer.midY),
                          bubble: rightOfCard)
        case .expandHUD:
            let expand = CGRect(x: notchRect.maxX + 30, y: notchRect.minY + 4, width: 30, height: 30)
            return Target(ring: expand, arrowTo: CGPoint(x: expand.maxX + 6, y: expand.midY), bubble: rightOfCard)
        case .backDown:
            return Target(ring: nil, arrowTo: nil, bubble: CGPoint(x: 40, y: size.height - 240))
        case .hide:
            return Target(ring: nil, arrowTo: nil, bubble: below)
        default:
            return Target(ring: nil, arrowTo: nil, bubble: below)
        }
    }

    // MARK: Layers

    @ViewBuilder
    private func annotations(size: CGSize) -> some View {
        let t = target(size: size)
        if let ring = t.ring {
            SketchRing(rect: ring, seed: state.step.rawValue)
                .trim(from: 0, to: draw)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(0.7), radius: 6)
                .shadow(color: accent.opacity(0.35), radius: 18)
        }
        if let to = t.arrowTo {
            let from = arrowStart(from: t.bubble, to: to, size: size)
            SketchArrow(from: from, to: to, seed: state.step.rawValue)
                .trim(from: 0, to: draw)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(0.6), radius: 6)
        }
    }

    /// The arrow leaves the bubble from whichever edge faces the target.
    private func arrowStart(from bubble: CGPoint, to: CGPoint, size: CGSize) -> CGPoint {
        let bw: CGFloat = 380, bh: CGFloat = 150
        let rect = CGRect(origin: bubble, size: CGSize(width: bw, height: bh))
        if to.y < rect.minY { return CGPoint(x: rect.midX, y: rect.minY - 8) }
        if to.x < rect.minX { return CGPoint(x: rect.minX - 8, y: rect.midY) }
        if to.x > rect.maxX { return CGPoint(x: rect.maxX + 8, y: rect.midY) }
        return CGPoint(x: rect.midX, y: rect.maxY + 8)
    }

    private func bubble(size: CGSize) -> some View {
        let t = target(size: size)
        return GuideBubble(line: state.line, step: state.step, started: state.stepStarted)
            .frame(width: 380, alignment: .topLeading)
            .position(x: t.bubble.x + 190, y: t.bubble.y + 75)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .id(state.step)
    }

    private func boot(size: CGSize, origin: CGPoint) -> some View {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2 - 40)
        let flew = bootPhase == 2
        return ZStack {
            HeroMark(size: 300)
                .scaleEffect(bootPhase == 0 ? 0.6 : (flew ? 0.04 : 1))
                .opacity(bootPhase == 0 ? 0 : (flew ? 0 : 1))
                .position(flew ? origin : centre)

            VStack(spacing: 14) {
                TypewriterText("VISOR", start: state.stepStarted, cps: reduced ? 1000 : 9)
                    .font(.custom(Design.Text.face, size: 84)).tracking(18)
                    .foregroundStyle(.white)
                    .shadow(color: accent.opacity(0.8), radius: 24)
                Text(state.line.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(state.line.body)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .position(x: size.width / 2, y: centre.y + 240)
            .opacity(bootPhase == 0 ? 0 : (flew ? 0 : 1))
        }
        .accessibilityIdentifier("visor.takeover.boot")
    }

    private func finale(size: CGSize) -> some View {
        let k = ShortcutSettings.hint(.toggle)
        let keys: [(String, String)] = [
            (k, "open · close"),
            (ShortcutSettings.hint(.swapMode), "notes ↔ chat"),
            (ShortcutSettings.hint(.hud), "expand to the HUD"),
            (ShortcutSettings.hint(.dictate), "dictate anywhere"),
        ]
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                HeroMark(size: 44)
                Text(state.line.kicker)
                    .font(.custom(Design.Text.face, size: 13)).tracking(3)
                    .foregroundStyle(accent)
            }
            Text(state.line.title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
            Text(state.line.body)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.68))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ForEach(keys, id: \.0) { key, label in
                    VStack(spacing: 8) {
                        Text(key)
                            .font(.custom(Design.Text.face, size: 15))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.22), lineWidth: 1))
                        Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            HStack(spacing: 10) {
                Button(action: onAddAgent) {
                    Text("Add an agent")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Design.Retro.onAccent)
                        .padding(.horizontal, 18).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill(accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.visorBare)
                .accessibilityIdentifier("visor.takeover.addAgent")
                Button(action: onDone) {
                    Text("I'm good")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 16).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.visorBare)
                .accessibilityIdentifier("visor.takeover.done")
            }
        }
        .padding(30)
        .frame(width: 560, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Design.Retro.bg.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(accent.opacity(0.5), lineWidth: 1))
        .shadow(color: accent.opacity(0.25), radius: 40)
        // Below the card, never over it.
        .position(x: size.width / 2, y: max(size.height / 2 + 40, card.maxY + 40 + 250))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .accessibilityIdentifier("visor.takeover.finale")
    }

    private var skip: some View {
        Button(action: onSkip) {
            Text(state.step == .finale ? "Close" : "Skip the tour")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.visorBare)
        .accessibilityIdentifier("visor.takeover.skip")
    }
}

// MARK: - The guide

/// The speech bubble: kicker in the pixel face, the instruction, a body
/// that types itself, the step dots, and the mark bobbing at its shoulder.
private struct GuideBubble: View {
    let line: TakeoverState.Line
    let step: TakeoverState.Step
    let started: Date

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(line.kicker)
                        .font(.custom(Design.Text.face, size: 11)).tracking(2)
                        .foregroundStyle(Design.Retro.accent)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        ForEach(1..<8, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(i <= progress ? Design.Retro.accent : Color.white.opacity(0.18))
                                .frame(width: i == progress ? 14 : 6, height: 3)
                        }
                    }
                }
                Text(line.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                TypewriterText(line.body, start: started, cps: 70)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20).padding(.bottom, 18).padding(.horizontal, 22)
            .frame(width: 380, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Design.Retro.bg.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Design.Retro.accent.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            .shadow(color: Design.Retro.accent.opacity(0.18), radius: 30)

            HeroMark(size: 60)
                .offset(x: -30, y: -30)
        }
        .accessibilityIdentifier("visor.takeover.bubble")
    }

    private var progress: Int {
        switch step {
        case .boot: return 0
        case .clickNotch: return 1
        case .addTask: return 2
        case .swapToChat: return 3
        case .ask: return 4
        case .expandHUD, .backDown: return 5
        case .hide: return 6
        case .summon, .finale: return 7
        }
    }
}

/// The mark: the Blender-rendered trefoil turning, or the flat BeamMark if
/// the sheet isn't bundled. Bobs gently so it reads as alive, not pasted.
struct HeroMark: View {
    var size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: Design.Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let bob = Design.Motion.reduced ? 0 : sin(t * 1.6) * size * 0.04
            Group {
                if let sheet = HeroSheet.image {
                    HeroSheet.frame(sheet, index: Int(t * 24) % HeroSheet.count, size: size)
                } else {
                    BeamMark()
                        .frame(width: size * 0.7, height: size * 0.62)
                        .foregroundStyle(Design.Retro.accent)
                }
            }
            .offset(y: bob)
            .shadow(color: Design.Retro.accent.opacity(0.55), radius: size * 0.18)
        }
        .frame(width: size, height: size)
    }
}

/// The turntable sprite sheet: 36 frames of the trefoil in a 6×6 grid,
/// rendered in Blender (see docs/design-lab.md). Loaded once.
enum HeroSheet {
    static let count = 36
    static let columns = 6
    static let cell: CGFloat = 320
    static let image: NSImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("hero-sheet.png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }()

    static func frame(_ sheet: NSImage, index: Int, size: CGFloat) -> some View {
        let scale = size / cell
        let col = CGFloat(index % columns), row = CGFloat(index / columns)
        return Image(nsImage: sheet)
            .resizable()
            .frame(width: cell * CGFloat(columns) * scale, height: cell * CGFloat(count / columns) * scale)
            .offset(x: -col * cell * scale, y: -row * cell * scale)
            .frame(width: size, height: size, alignment: .topLeading)
            .clipped()
    }
}

// MARK: - Effects

/// Text that arrives a character at a time.
struct TypewriterText: View {
    let text: String
    let start: Date
    var cps: Double = 60

    init(_ text: String, start: Date, cps: Double = 60) {
        self.text = text
        self.start = start
        self.cps = cps
    }

    var body: some View {
        TimelineView(.periodic(from: start, by: 1 / 30)) { context in
            let shown = Design.Motion.reduced
                ? text.count
                : min(text.count, Int(context.date.timeIntervalSince(start) * cps))
            // Layout on the full string so the bubble never resizes as
            // letters arrive; only the visible prefix is inked.
            Text(text).opacity(0)
                .overlay(Text(String(text.prefix(max(0, shown)))), alignment: .topLeading)
        }
    }
}

/// Faint horizontal lines every third point: the CRT under the pixel face.
private struct Scanlines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            var path = Path()
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += 3
            }
            context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// One bright band sweeping down the screen as the takeover powers on.
private struct CRTSweep: View {
    let start: Date
    let height: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            let duration = 1.1
            if t < duration {
                let p = t / duration
                let y = CGFloat(p) * (height + 200) - 100
                LinearGradient(colors: [.clear, Design.Retro.accent.opacity(0.28), .white.opacity(0.35), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
                    .offset(y: y - 80)
                    .opacity(1 - p * 0.6)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Pixels drifting into the notch, and a burst out of it when a step lands.
///
/// Every particle is a pure function of time and its index, so the field
/// costs one Canvas pass per frame and never accumulates state.
private struct PixelField: View {
    let origin: CGPoint
    let size: CGSize
    let burstAt: Date
    var density: Double = 1

    private static let ambient = 110
    private static let burst = 72

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let age = context.date.timeIntervalSince(burstAt)
            Canvas { ctx, _ in
                let accent = Design.Retro.accent
                let count = Int(Double(Self.ambient) * density)
                for i in 0..<count {
                    let s = seed(i)
                    let speed = 0.03 + s.0 * 0.05
                    let f = ((now * speed) + s.1).truncatingRemainder(dividingBy: 1)
                    let startX = s.2 * size.width
                    let startY = size.height * (0.35 + s.3 * 0.75)
                    let sway = sin(now * 1.3 + s.1 * 20) * 18 * (1 - f)
                    let x = startX + (origin.x - startX) * pow(f, 1.6) + sway
                    let y = startY + (origin.y - startY) * pow(f, 1.6)
                    let px = 1.5 + s.0 * 2
                    let alpha = sin(f * .pi) * (0.25 + s.3 * 0.45)
                    ctx.fill(Path(CGRect(x: x, y: y, width: px, height: px)),
                             with: .color((i % 3 == 0 ? Color.white : accent).opacity(alpha)))
                }
                if age >= 0, age < 1.5 {
                    let e = 1 - pow(1 - age / 1.5, 3)
                    for i in 0..<Self.burst {
                        let s = seed(i + 1000)
                        let angle = s.0 * .pi * 2
                        let dist = (80 + s.1 * 260) * e
                        let x = origin.x + cos(angle) * dist
                        let y = origin.y + abs(sin(angle)) * dist + age * age * 140
                        let px = 2 + s.2 * 3
                        let alpha = (1 - e) * 0.95
                        ctx.fill(Path(CGRect(x: x, y: y, width: px, height: px)),
                                 with: .color((i % 2 == 0 ? Color.white : accent).opacity(alpha)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Four stable pseudo-random numbers in 0…1 for a particle.
    private func seed(_ i: Int) -> (Double, Double, Double, Double) {
        func r(_ k: Double) -> Double {
            let v = sin(Double(i) * 12.9898 + k * 78.233) * 43758.5453
            return v - floor(v)
        }
        return (r(1), r(2), r(3), r(4))
    }
}

/// The screen minus some rectangles, for an even-odd fill or mask. The card
/// hole keeps the card's rounded bottom so the scrim hugs its silhouette.
struct Cutout: Shape {
    let holes: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        for hole in holes {
            if hole.height > 200 {
                path.addRoundedRect(in: hole, cornerSize: CGSize(width: 18, height: 18))
            } else {
                path.addRect(hole)
            }
        }
        return path
    }
}

// MARK: - Sketch strokes

/// A ring that looks drawn by hand: an ellipse whose radius wobbles a
/// little along the way, overshooting where it closes.
struct SketchRing: Shape {
    let rect: CGRect
    var seed: Int

    func path(in _: CGRect) -> Path {
        var path = Path()
        let steps = 64
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        for i in 0...steps {
            let a = -0.4 + (Double(i) / Double(steps)) * (.pi * 2 + 0.55)
            let w = wobble(i) * 2.6
            let ca = CGFloat(Foundation.cos(a)), sa = CGFloat(Foundation.sin(a))
            let p = CGPoint(x: cx + ca * (rx + w), y: cy + sa * (ry + w * 0.8))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func wobble(_ i: Int) -> CGFloat {
        let v = sin(Double(i) * 3.7 + Double(seed) * 11.3) * 43758.5453
        return CGFloat(v - floor(v)) * 2 - 1
    }
}

/// A slightly bowed arrow with a two-stroke head.
struct SketchArrow: Shape {
    let from: CGPoint
    let to: CGPoint
    var seed: Int

    func path(in _: CGRect) -> Path {
        var path = Path()
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(1, sqrt(dx * dx + dy * dy))
        let nx = -dy / length, ny = dx / length
        let bow = (seed % 2 == 0 ? 1 : -1) * length * 0.14
        let control = CGPoint(x: (from.x + to.x) / 2 + nx * bow, y: (from.y + to.y) / 2 + ny * bow)
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        // Head, angled off the incoming tangent.
        let tx = to.x - control.x, ty = to.y - control.y
        let tl = max(1, sqrt(tx * tx + ty * ty))
        let ux = tx / tl, uy = ty / tl
        let head: CGFloat = 13
        let cs = CGFloat(Foundation.cos(0.55)), sn = CGFloat(Foundation.sin(0.55))
        let left = CGPoint(x: to.x - head * (ux * cs - uy * sn),
                           y: to.y - head * (uy * cs + ux * sn))
        let right = CGPoint(x: to.x - head * (ux * cs + uy * sn),
                            y: to.y - head * (uy * cs - ux * sn))
        path.move(to: left)
        path.addLine(to: to)
        path.addLine(to: right)
        return path
    }
}
