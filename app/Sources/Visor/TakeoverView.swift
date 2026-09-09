import AppKit
import SwiftUI

/// The takeover's picture: a scrim over the Mac with real holes cut for the
/// card, the notch and the practice window; scanlines; a field of pixels
/// drifting into the notch; rough accent strokes around the real thing to
/// do next; a guide with a speech bubble and the controls each moment
/// needs; the 3D mark rising from the notch on boot; a cheat sheet at the
/// end. Built from the design system's components — the bubble's buttons
/// are the product's `ActionChip`s and `ExampleChip`s.
struct TakeoverView: View {
    @ObservedObject var state: TakeoverState
    var actions: TakeoverActions

    @State private var draw: CGFloat = 0
    @State private var bootPhase = 0   // 0 arriving, 1 risen, 2 flew back into the notch
    /// The mark travelling from the bubble to the thing that just happened.
    @State private var traveller: CGPoint? = nil
    @State private var travelling = false

    private var reduced: Bool { Design.Motion.reduced }
    private var accent: Color { Design.Retro.accent }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let notch = view(state.geometry.notch)
            let origin = CGPoint(x: notch.midX, y: notch.maxY)

            // The card's hole is the card's rect under the card's own
            // transition: a scale from 0.02 at its top centre. The scale is
            // what animates, and it changes inside the notch controller's
            // own withAnimation transaction (the guide's sink runs
            // synchronously on the publish), so the hole and the card are
            // one motion with one curve. Closed, the hole is a few points
            // hidden inside the physical notch — never a rectangle beside it.
            let scrim = Scrim(card: cardRect(size: size), scale: state.geometry.hud || state.geometry.expanded ? 1 : 0.02,
                              extras: extraHoles(size: size))

            ZStack(alignment: .topLeading) {
                scrim
                    .fill(Color.black.opacity(scrimOpacity), style: FillStyle(eoFill: true))
                    .animation(Design.Motion.animation(.easeInOut(duration: 0.4)), value: state.step)

                if !reduced {
                    Group {
                        Scanlines()
                        if state.step == .boot { CRTSweep(start: state.stepStarted, height: size.height) }
                        PixelField(origin: origin, size: size, burstAt: state.lastBurst)
                    }
                    .mask(scrim.fill(style: FillStyle(eoFill: true)))
                }

                // The notch's click band, while the card is closed: the scrim
                // covers it, so the click comes here and is passed on. No hole,
                // no lit rectangle — the notch is black hardware either way.
                if !state.geometry.expanded, state.step == .summon {
                    Color.black.opacity(0.001)
                        .frame(width: notchRect.width + 12, height: notchRect.height + 12)
                        .position(x: notchRect.midX, y: notchRect.midY + 6)
                        .onTapGesture(perform: actions.summon)
                        .accessibilityIdentifier("visor.takeover.notchTarget")
                }

                annotations(size: size, origin: origin)

                switch state.step {
                case .boot:    boot(size: size, origin: origin)
                case .finale:  finale(size: size)
                default:       bubble(size: size)
                }

                if let point = traveller {
                    HeroMark(size: 44)
                        .position(point)
                        .opacity(travelling ? 1 : 0)
                        .allowsHitTesting(false)
                }

                if let milestone = state.milestone {
                    MilestoneBadge(text: milestone)
                        // Below the card and the practice window, never over
                        // the thing that just succeeded.
                        .position(x: size.width / 2, y: max(size.height * 0.42, card.maxY + 70))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                topBar(size: size)
            }
            .onChange(of: state.bursts) { _ in travel(size: size, origin: origin) }
            .frame(width: size.width, height: size.height)
            .onChange(of: state.step) { _ in
                draw = 0
                withAnimation(Design.Motion.animation(.easeOut(duration: 0.85))) { draw = 1 }
            }
            .onAppear {
                withAnimation(Design.Motion.animation(.easeOut(duration: 0.85))) { draw = 1 }
                if Date().timeIntervalSince(state.stepStarted) > 1.5 { bootPhase = 1 }
                let rise = reduced ? 0.1 : 0.3
                let settle = reduced ? 0.5 : 2.9
                DispatchQueue.main.asyncAfter(deadline: .now() + rise) {
                    withAnimation(Design.Motion.animation(.spring(response: 0.9, dampingFraction: 0.78))) { bootPhase = 1 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    withAnimation(Design.Motion.animation(Design.Motion.hud)) { bootPhase = 2 }
                }
            }
        }
        .opacity(state.leaving ? 0 : 1)
        .accessibilityIdentifier("visor.takeover")
    }

    private var scrimOpacity: Double {
        if state.leaving { return 0 }
        return state.step == .boot ? 0.9 : 0.76
    }

    /// The rect the card occupies when open (the whole screen for the HUD).
    private func cardRect(size: CGSize) -> CGRect {
        state.geometry.hud ? CGRect(origin: .zero, size: size) : card
    }

    private func extraHoles(size: CGSize) -> [CGRect] { [] }

    /// When a step lands, the mark leaves the bubble, flies to what happened
    /// and vanishes in the burst — the reward travels to the thing you did.
    private func travel(size: CGSize, origin: CGPoint) {
        guard !reduced, state.step != .boot else { return }
        let t = target(size: size)
        let from = CGPoint(x: t.bubble.x, y: t.bubble.y)
        let to = t.ring.map { CGPoint(x: $0.midX, y: $0.midY) } ?? origin
        traveller = from
        travelling = true
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { traveller = to }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.2)) { travelling = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { traveller = nil }
    }

    // MARK: Coordinates

    private func view(_ r: CGRect) -> CGRect {
        let b = state.geometry.bounds
        return CGRect(x: r.minX - b.minX, y: b.maxY - r.maxY, width: r.width, height: r.height)
    }

    private var card: CGRect { view(state.geometry.card) }
    private var notchRect: CGRect { view(state.geometry.notch) }
    private var notchH: CGFloat { notchRect.height }

    private struct Target {
        var ring: CGRect?
        var arrowTo: CGPoint?
        var bubble: CGPoint
        var bubbleHeight: CGFloat = 170
    }

    private let bubbleWidth: CGFloat = 400

    private func target(size: CGSize) -> Target {
        let c = card
        let bw = bubbleWidth
        // One home for the guide once the card is open — beside it, clear of
        // the top bar — so nothing on screen hops between moments.
        let beside = CGPoint(x: min(c.maxX + 48, size.width - bw - 32), y: c.minY + notchH + 76)
        let composer = CGRect(x: c.minX + 10, y: c.maxY - 118, width: c.width - 20, height: 106)
        let identity = CGRect(x: c.minX + 10, y: c.minY + notchH + 30, width: 210, height: 30)
        switch state.step {
        case .summon:
            let ring = notchRect.insetBy(dx: -22, dy: -14)
            return Target(ring: ring, arrowTo: CGPoint(x: ring.midX, y: ring.maxY + 6),
                          bubble: CGPoint(x: size.width / 2 - bw / 2, y: notchRect.maxY + 150))
        case .agent:
            return Target(ring: state.created ? identity : nil,
                          arrowTo: state.created ? CGPoint(x: identity.maxX + 6, y: identity.midY) : nil,
                          bubble: beside, bubbleHeight: 320)
        case .firstTask:
            let ring = (state.awaitingApproval || state.taskDone) ? nil : composer
            return Target(ring: ring, arrowTo: ring.map { CGPoint(x: $0.maxX + 6, y: $0.midY) },
                          bubble: beside)
        case .drive:
            // The Stop control in the Computer Use card's task field.
            let stop = CGRect(x: c.maxX - 62, y: c.minY + notchH + 42, width: 44, height: 44)
            return Target(ring: state.askStop ? stop : nil,
                          arrowTo: state.askStop ? CGPoint(x: stop.maxX + 6, y: stop.midY) : nil,
                          bubble: beside)
        default:
            return Target(ring: nil, arrowTo: nil, bubble: CGPoint(x: size.width / 2 - bw / 2, y: c.maxY + 72))
        }
    }

    // MARK: Layers

    @ViewBuilder
    private func annotations(size: CGSize, origin: CGPoint) -> some View {
        let t = target(size: size)
        if let ring = t.ring {
            SketchRing(rect: ring, seed: state.step.rawValue)
                .trim(from: 0, to: draw)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(0.7), radius: 6)
                .shadow(color: accent.opacity(0.35), radius: 18)
        }
        if let to = t.arrowTo {
            let from = arrowStart(from: t.bubble, height: t.bubbleHeight, to: to)
            SketchArrow(from: from, to: to, seed: state.step.rawValue)
                .trim(from: 0, to: draw)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(0.6), radius: 6)
        }
    }

    private func arrowStart(from bubble: CGPoint, height: CGFloat, to: CGPoint) -> CGPoint {
        let rect = CGRect(origin: bubble, size: CGSize(width: bubbleWidth, height: height))
        if to.y < rect.minY { return CGPoint(x: rect.midX, y: rect.minY - 8) }
        if to.x < rect.minX { return CGPoint(x: rect.minX - 8, y: rect.midY) }
        if to.x > rect.maxX { return CGPoint(x: rect.maxX + 8, y: rect.midY) }
        return CGPoint(x: rect.midX, y: rect.maxY + 8)
    }

    /// One bubble for the whole tour. It glides between moments rather than
    /// being replaced, so the guide reads as a companion that moves, not a
    /// series of cards.
    private func bubble(size: CGSize) -> some View {
        let t = target(size: size)
        return GuideBubble(state: state, actions: actions)
            .frame(width: bubbleWidth, alignment: .topLeading)
            .position(x: t.bubble.x + bubbleWidth / 2, y: t.bubble.y + t.bubbleHeight / 2)
            .animation(Design.Motion.animation(.spring(response: 0.6, dampingFraction: 0.86)), value: state.step)
            .transition(.opacity)
    }

    /// The reveal: the mark rises out of the notch, turns once above it
    /// while the wordmark types, then drops back in — everything emanates
    /// from the notch, including Visor itself.
    private func boot(size: CGSize, origin: CGPoint) -> some View {
        let risen = CGPoint(x: origin.x, y: origin.y + 210)
        let flew = bootPhase == 2
        return ZStack {
            HeroMark(size: 260)
                .scaleEffect(bootPhase == 0 ? 0.08 : (flew ? 0.06 : 1))
                .opacity(bootPhase == 0 ? 0 : (flew ? 0 : 1))
                .position(bootPhase == 1 ? risen : origin)

            VStack(spacing: 12) {
                TypewriterText("VISOR", start: state.stepStarted, cps: reduced ? 1000 : 9)
                    .font(.custom(Design.Text.face, size: 72)).tracking(16)
                    .foregroundStyle(.white)
                    .shadow(color: accent.opacity(0.8), radius: 24)
                Text(state.line.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Design.Ink.primary)
                Text(state.line.body)
                    .font(.system(size: 15))
                    .foregroundStyle(Design.Ink.secondary)
            }
            .position(x: size.width / 2, y: risen.y + 230)
            .opacity(bootPhase == 1 ? 1 : 0)
        }
        .accessibilityIdentifier("visor.takeover.boot")
    }

    private func finale(size: CGSize) -> some View {
        let keys: [(String, String)] = [
            (ShortcutSettings.hint(.toggle), "summon · put away"),
            (ShortcutSettings.hint(.hud), "expand to the HUD"),
            (ShortcutSettings.hint(.dictate), "dictate anywhere"),
            ("⌘.", "stop a reply"),
        ]
        return VStack(alignment: .leading, spacing: Design.Space.wide) {
            HStack(spacing: Design.Space.roomy) {
                HeroMark(size: 44)
                SectionLabel(state.line.kicker, tint: accent)
            }
            Text(state.line.title)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
            Text(state.line.body)
                .font(Design.Typography.body())
                .foregroundStyle(Design.Ink.secondary)
                .lineSpacing(Design.Typography.bodyLeading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Design.Space.roomy) {
                ForEach(keys, id: \.0) { key, label in
                    VStack(spacing: Design.Space.normal) {
                        Text(key)
                            .font(.custom(Design.Text.face, size: 15))
                            .foregroundStyle(Design.Ink.primary)
                            .padding(.horizontal, Design.Space.roomy).frame(height: 36)
                            .raised(Design.Radius.control, strong: true, stroke: Design.Stroke.control)
                        Text(label).font(Design.Typography.caption()).foregroundStyle(Design.Ink.tertiary)
                    }
                }
            }

            ActionChip(title: "Finish", prominent: true, action: actions.finish)
                .accessibilityIdentifier("visor.takeover.finish")
        }
        .padding(Design.Space.section + 6)
        .frame(width: 560, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .fill(Design.Retro.bg.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .strokeBorder(accent.opacity(0.5), lineWidth: Design.Stroke.hairline))
        .shadow(color: accent.opacity(0.25), radius: 40)
        .position(x: size.width / 2, y: max(size.height / 2 + 40, card.maxY + 40 + 230))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .accessibilityIdentifier("visor.takeover.finale")
    }

    /// Skip and the step count, out of the way at the top right. No Back:
    /// the story drives itself, and a replay is one click away afterwards.
    private func topBar(size: CGSize) -> some View {
        HStack(spacing: Design.Space.normal) {
            if state.step != .boot, state.step != .finale {
                Text("\(state.step.rawValue) / 4")
                    .font(Design.Typography.mono(0.9))
                    .foregroundStyle(Design.Ink.faint)
            }
            ActionChip(title: state.step == .finale ? "Close" : "Skip the tour", action: actions.skip)
                .accessibilityIdentifier("visor.takeover.skip")
        }
        .position(x: size.width - 120, y: 44)
    }
}

// MARK: - The guide

/// The speech bubble: kicker in the study's label face, the instruction,
/// a body that types itself, the step dots, the moment's own controls,
/// and the mark at its shoulder.
private struct GuideBubble: View {
    @ObservedObject var state: TakeoverState
    var actions: TakeoverActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Design.Space.roomy) {
                HStack(spacing: Design.Space.normal) {
                    SectionLabel(state.line.kicker, tint: Design.Retro.accent)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        ForEach(1..<5, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(i <= state.step.rawValue ? Design.Retro.accent : Color.white.opacity(0.18))
                                .frame(width: i == state.step.rawValue ? 14 : 6, height: 3)
                        }
                    }
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Design.Space.roomy) {
                    Text(state.line.title)
                        .font(Design.Typography.display())
                        .foregroundStyle(Design.Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    TypewriterText(state.line.body, start: state.stepStarted, cps: 80)
                        .font(Design.Typography.body())
                        .foregroundStyle(Design.Ink.secondary)
                        .lineSpacing(Design.Typography.bodyLeading)
                        .fixedSize(horizontal: false, vertical: true)

                    controls
                }
                .id("\(state.step.rawValue)-\(state.trouble == nil)-\(state.taskDone)-\(state.awaitingApproval)-\(state.created)-\(state.askStop)-\(state.driveStopped)-\(state.driveDone)")
                .transition(.opacity)
            }
            .animation(Design.Motion.animation(.easeInOut(duration: 0.22)), value: state.step)
            .animation(Design.Motion.animation(.easeInOut(duration: 0.22)), value: state.trouble == nil)
            .padding(.top, Design.Space.wide).padding(.bottom, Design.Space.loose)
            .padding(.horizontal, Design.Space.section)
            .frame(width: 400, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(Design.Retro.bg.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(Design.Retro.accent.opacity(0.55), lineWidth: Design.Stroke.hairline))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            .shadow(color: Design.Retro.accent.opacity(0.18), radius: 30)

            HeroMark(size: 60)
                .offset(x: -30, y: -30)
        }
        .accessibilityIdentifier("visor.takeover.bubble")
    }

    /// The tour's one form, and nothing else: name, connection, Create.
    @ViewBuilder
    private var controls: some View {
        if state.step == .agent, !state.created {
            AgentForm(state: state, create: actions.createAgent)
                .padding(.top, Design.Space.tight)
        }
    }
}

/// Name and connect an agent — the only thing the introduction asks the
/// person to do. A found, signed-in CLI is one click; otherwise a key.
private struct AgentForm: View {
    @ObservedObject var state: TakeoverState
    let create: () -> Void
    @FocusState private var focus: Field?
    private enum Field { case name, key }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            VStack(alignment: .leading, spacing: Design.Space.snug) {
                SectionLabel("Name")
                TextField("Claude", text: $state.agentName)
                    .textFieldStyle(.plain)
                    .font(Design.Typography.body())
                    .foregroundStyle(Design.Ink.primary)
                    .focused($focus, equals: .name)
                    .padding(.horizontal, Design.Space.roomy)
                    .frame(height: Design.Metric.large)
                    .raised(Design.Radius.control, strong: true,
                            stroke: focus == .name ? Design.Stroke.control : Design.Stroke.edge)
                    .onSubmit { if state.connection == .openRouter, !state.hasKey { focus = .key } else if state.canCreate { create() } }
                    .accessibilityIdentifier("visor.takeover.agentName")
            }

            VStack(alignment: .leading, spacing: Design.Space.snug) {
                SectionLabel("Runs on")
                SelectorSegments(
                    options: [(String?.some("cli"), state.cliFound?.name ?? "Claude Code"),
                              (String?.some("openrouter"), "OpenRouter key")],
                    selected: state.connection == .cli ? "cli" : "openrouter") { id in
                        state.connection = id == "cli" ? .cli : .openRouter
                    }
                if state.connection == .cli {
                    Text(state.cliFound.map { "\($0.name) on this Mac, \($0.detail)." }
                         ?? "No signed-in CLI found on this Mac. Install Claude Code and sign in, or use a key.")
                        .font(Design.Typography.caption())
                        .foregroundStyle(state.cliFound == nil ? Design.Ink.warning : Design.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state.hasKey {
                    Text("A key is already saved. Any model on OpenRouter.")
                        .font(Design.Typography.caption())
                        .foregroundStyle(Design.Ink.tertiary)
                } else {
                    SecureField("sk-or-v1-…", text: $state.keyInput)
                        .textFieldStyle(.plain)
                        .font(Design.Typography.mono())
                        .foregroundStyle(Design.Ink.primary)
                        .focused($focus, equals: .key)
                        .padding(.horizontal, Design.Space.roomy)
                        .frame(height: Design.Metric.large)
                        .raised(Design.Radius.control, strong: true,
                                stroke: focus == .key ? Design.Stroke.control : Design.Stroke.edge)
                        .onSubmit { if state.canCreate { create() } }
                        .accessibilityIdentifier("visor.takeover.key")
                    Text("From openrouter.ai/keys. It stays in your Keychain.")
                        .font(Design.Typography.caption())
                        .foregroundStyle(Design.Ink.tertiary)
                }
            }

            if let error = state.formError {
                Text(error).font(Design.Typography.caption()).foregroundStyle(Design.Ink.warning)
            }

            ActionChip(title: state.creating ? "Creating…" : "Create \(state.agentName.trimmingCharacters(in: .whitespaces).isEmpty ? "agent" : state.agentName)",
                       prominent: true, action: create)
                .disabled(!state.canCreate)
                .opacity(state.canCreate ? 1 : 0.5)
                .accessibilityIdentifier("visor.takeover.create")
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = .name } }
    }
}

/// The mark: the Blender-rendered trefoil turning/// The mark: the Blender-rendered trefoil turning, or the flat BeamMark if
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
/// Every particle is a pure function of time and its index.
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

    private func seed(_ i: Int) -> (Double, Double, Double, Double) {
        func r(_ k: Double) -> Double {
            let v = sin(Double(i) * 12.9898 + k * 78.233) * 43758.5453
            return v - floor(v)
        }
        return (r(1), r(2), r(3), r(4))
    }
}

/// The screen minus the card and any extra windows, for an even-odd fill
/// or mask. The card hole is the card's rect scaled about its top centre —
/// the same transform as the card's own scale transition — and the scale
/// is the animatable value, so the hole and the card share one motion.
struct Scrim: Shape {
    var card: CGRect
    var scale: CGFloat
    var extras: [CGRect] = []

    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        let s = max(0, min(1, scale))
        if s > 0.001, card.width > 0, card.height > 0 {
            let w = card.width * s, h = card.height * s
            let hole = CGRect(x: card.midX - w / 2, y: card.minY, width: w, height: h)
            let r = min(Design.Radius.card * s, h / 2)
            path.addPath(Path(roundedRect: hole, cornerRadii: RectangleCornerRadii(
                topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0)))
        }
        for hole in extras {
            path.addPath(Path(roundedRect: hole, cornerRadius: 10))
        }
        return path
    }
}

/// A moment's worth of celebration: a check that draws on and one line.
struct MilestoneBadge: View {
    let text: String
    @State private var drawn: CGFloat = 0

    var body: some View {
        HStack(spacing: Design.Space.roomy) {
            ZStack {
                Circle().fill(Design.Retro.accent.opacity(0.18))
                Circle().strokeBorder(Design.Retro.accent, lineWidth: 2)
                CheckMark()
                    .trim(from: 0, to: drawn)
                    .stroke(Design.Retro.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(11)
            }
            .frame(width: 40, height: 40)
            .shadow(color: Design.Retro.accent.opacity(0.6), radius: 12)
            Text(text)
                .font(Design.Typography.display())
                .foregroundStyle(Design.Ink.primary)
        }
        .padding(.horizontal, Design.Space.section)
        .padding(.vertical, Design.Space.loose)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .fill(Design.Retro.bg.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .strokeBorder(Design.Retro.accent.opacity(0.6), lineWidth: Design.Stroke.hairline))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .onAppear { withAnimation(Design.Motion.animation(.easeOut(duration: 0.45))) { drawn = 1 } }
        .accessibilityIdentifier("visor.takeover.milestone")
    }
}

private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return p
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
        let tx = to.x - control.x, ty = to.y - control.y
        let tl = max(1, sqrt(tx * tx + ty * ty))
        let ux = tx / tl, uy = ty / tl
        let head: CGFloat = 13
        let cs = CGFloat(Foundation.cos(0.55)), sn = CGFloat(Foundation.sin(0.55))
        let left = CGPoint(x: to.x - head * (ux * cs - uy * sn), y: to.y - head * (uy * cs + ux * sn))
        let right = CGPoint(x: to.x - head * (ux * cs + uy * sn), y: to.y - head * (uy * cs - ux * sn))
        path.move(to: left)
        path.addLine(to: to)
        path.addLine(to: right)
        return path
    }
}
