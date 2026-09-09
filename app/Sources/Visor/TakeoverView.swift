import AppKit
import AVFoundation
import SwiftUI

/// The introduction's picture, kept deliberately quiet: a dark scrim that
/// fades up over the Mac with the real card cut out of it; the welcome
/// video, or the mark rising out of the notch; one caption that follows
/// the voice; a single centred card for the one form and the goodbye; a
/// hand-drawn ring around the real thing to press; a thin line of
/// progress along the bottom. Nothing blinks, nothing scans, nothing
/// hops. The pace is the pace of speech.
struct TakeoverView: View {
    @ObservedObject var state: TakeoverState
    @ObservedObject private var narrator: Narrator
    var actions: TakeoverActions

    @State private var appeared = false
    @State private var draw: CGFloat = 0
    @State private var videoProgress: Double = 0

    init(state: TakeoverState, actions: TakeoverActions) {
        self.state = state
        self.actions = actions
        _narrator = ObservedObject(wrappedValue: state.narrator)
    }

    private var reduced: Bool { Design.Motion.reduced }
    private var accent: Color { Design.Retro.accent }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let origin = CGPoint(x: notchRect.midX, y: notchRect.maxY)
            // The card's hole is the card rect under the card's own
            // transition (a scale about its top centre). The scale changes
            // inside the notch controller's animation transaction, so hole
            // and card are one motion. Closed, it hides inside the notch.
            let scrim = Scrim(card: cardRect(size: size),
                              scale: state.geometry.hud || state.geometry.expanded ? 1 : 0.02)

            ZStack(alignment: .topLeading) {
                scrim
                    .fill(Color.black.opacity(scrimOpacity), style: FillStyle(eoFill: true))
                    .animation(Design.Motion.animation(.easeInOut(duration: 0.4)), value: state.step)

                // The notch's click band while the card is closed: the scrim
                // covers it, so the click lands here and the guide opens it.
                if !state.geometry.expanded, state.step == .notch {
                    Color.black.opacity(0.001)
                        .frame(width: notchRect.width + 12, height: notchRect.height + 12)
                        .position(x: notchRect.midX, y: notchRect.midY + 6)
                        .onTapGesture(perform: actions.summon)
                        .accessibilityIdentifier("visor.takeover.notchTarget")
                }

                annotations(size: size)

                if state.step == .intro {
                    intro(size: size, origin: origin)
                } else {
                    caption(size: size)
                }

                if state.step == .agent, state.formVisible, !state.created {
                    TourCard(width: 420) { AgentForm(state: state, create: actions.createAgent) }
                        .position(x: size.width / 2, y: cardHome(size: size))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                if state.step == .finale, state.sheetVisible {
                    TourCard(width: 560) { finaleSheet }
                        .position(x: size.width / 2, y: cardHome(size: size))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                topBar(size: size)
                progressBar(size: size)
            }
            .frame(width: size.width, height: size.height)
            .onChange(of: state.step) { _ in
                draw = 0
                withAnimation(Design.Motion.animation(.easeOut(duration: 0.85))) { draw = 1 }
            }
            .onChange(of: state.askStop) { _ in redraw() }
            .onChange(of: state.awaitingApproval) { _ in redraw() }
            .onAppear {
                // The scrim fades up; nothing else moves until it has.
                withAnimation(Design.Motion.animation(.easeInOut(duration: reduced ? 0.3 : 1.1))) { appeared = true }
                withAnimation(Design.Motion.animation(.easeOut(duration: 0.85))) { draw = 1 }
            }
        }
        .opacity(state.leaving ? 0 : 1)
        .accessibilityIdentifier("visor.takeover")
    }

    private func redraw() {
        draw = 0
        withAnimation(Design.Motion.animation(.easeOut(duration: 0.85))) { draw = 1 }
    }

    private var scrimOpacity: Double {
        guard appeared, !state.leaving else { return 0 }
        return state.step == .intro ? 0.88 : 0.74
    }

    // MARK: Coordinates

    private func view(_ r: CGRect) -> CGRect {
        let b = state.geometry.bounds
        return CGRect(x: r.minX - b.minX, y: b.maxY - r.maxY, width: r.width, height: r.height)
    }

    private var card: CGRect { view(state.geometry.card) }
    private var notchRect: CGRect { view(state.geometry.notch) }
    private var notchH: CGFloat { notchRect.height }

    private func cardRect(size: CGSize) -> CGRect {
        state.geometry.hud ? CGRect(origin: .zero, size: size) : card
    }

    /// Where the one tour card sits: centred in the room below the notch
    /// card, never over it.
    private func cardHome(size: CGSize) -> CGFloat {
        let below = state.geometry.expanded ? card.maxY : notchRect.maxY
        return max(size.height * 0.5, below + 40 + 190)
    }

    /// The caption's home: under the notch until the card opens, then beside
    /// the card, clear of the top bar. One place per moment, no hopping.
    private func captionHome(size: CGSize) -> CGPoint {
        let w: CGFloat = captionWidth
        if state.geometry.expanded {
            return CGPoint(x: min(card.maxX + 40, size.width - w - 32), y: card.minY + notchH + 72)
        }
        return CGPoint(x: size.width / 2 - w / 2, y: notchRect.maxY + 130)
    }

    private let captionWidth: CGFloat = 420

    // MARK: Annotations

    private struct Mark { var ring: CGRect; var arrowTo: CGPoint }

    private func mark(size: CGSize) -> Mark? {
        let c = card
        switch state.step {
        case .notch where !state.geometry.expanded:
            let ring = notchRect.insetBy(dx: -22, dy: -14)
            return Mark(ring: ring, arrowTo: CGPoint(x: ring.midX, y: ring.maxY + 6))
        case .task where state.awaitingApproval:
            // The approval row's Allow chip, at the foot of the transcript.
            let allow = CGRect(x: c.minX + 22, y: c.maxY - 168, width: 92, height: 34)
            return Mark(ring: allow, arrowTo: CGPoint(x: allow.maxX + 6, y: allow.midY))
        case .drive where state.askStop:
            let stop = CGRect(x: c.maxX - 62, y: c.minY + notchH + 42, width: 44, height: 44)
            return Mark(ring: stop, arrowTo: CGPoint(x: stop.maxX + 6, y: stop.midY))
        default:
            return nil
        }
    }

    @ViewBuilder
    private func annotations(size: CGSize) -> some View {
        if let m = mark(size: size) {
            SketchRing(rect: m.ring, seed: state.step.rawValue)
                .trim(from: 0, to: draw)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(0.5), radius: 8)
            let home = captionHome(size: size)
            let from = arrowStart(from: CGRect(origin: home, size: CGSize(width: captionWidth, height: 64)), to: m.arrowTo)
            SketchArrow(from: from, to: m.arrowTo, seed: state.step.rawValue)
                .trim(from: 0, to: draw)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(0.4), radius: 6)
        }
    }

    private func arrowStart(from rect: CGRect, to: CGPoint) -> CGPoint {
        if to.y < rect.minY { return CGPoint(x: rect.midX, y: rect.minY - 8) }
        if to.x < rect.minX { return CGPoint(x: rect.minX - 8, y: rect.midY) }
        if to.x > rect.maxX { return CGPoint(x: rect.maxX + 8, y: rect.midY) }
        return CGPoint(x: rect.midX, y: rect.maxY + 8)
    }

    // MARK: Intro

    /// The welcome: the founder's video if one is bundled, with a thin bar
    /// of progress beneath it; otherwise the mark rises out of the notch
    /// while the voice says hello, and settles back in.
    @ViewBuilder
    private func intro(size: CGSize, origin: CGPoint) -> some View {
        if let url = state.videoURL {
            let w = min(960, size.width - 160), h = w * 9 / 16
            VStack(spacing: 0) {
                VideoIntro(url: url, progress: $videoProgress, muted: !narrator.soundOn, onEnd: actions.videoEnded)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 40, y: 16)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule().fill(accent).frame(width: g.size.width * videoProgress)
                    }
                }
                .frame(width: w, height: 3)
                .padding(.top, Design.Space.roomy)
            }
            .position(x: size.width / 2, y: size.height / 2 + 10)
            .opacity(appeared ? 1 : 0)
            .accessibilityIdentifier("visor.takeover.video")
        } else {
            let risen = CGPoint(x: origin.x, y: origin.y + 190)
            ZStack {
                HeroMark(size: 220)
                    .scaleEffect(state.risen ? 1 : 0.06)
                    .opacity(state.risen ? 1 : 0)
                    .position(state.risen ? risen : origin)
                VStack(spacing: Design.Space.wide) {
                    Text("Visor")
                        .font(.system(size: 54, weight: .semibold, design: .default))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                    Text(narrator.line)
                        .font(.system(size: 19))
                        .foregroundStyle(Design.Ink.secondary)
                        .multilineTextAlignment(.center)
                        .id(narrator.line)
                        .transition(.opacity)
                }
                .animation(Design.Motion.animation(.easeInOut(duration: 0.35)), value: narrator.line)
                .position(x: size.width / 2, y: risen.y + 200)
                .opacity(state.risen ? 1 : 0)
            }
            .accessibilityIdentifier("visor.takeover.intro")
        }
    }

    // MARK: Caption

    /// The voice, written down: the mark and the line it is saying. When
    /// something lands, the mark becomes a check for a moment.
    private func caption(size: CGSize) -> some View {
        let home = captionHome(size: size)
        let text = state.milestone ?? narrator.line
        return HStack(alignment: .center, spacing: Design.Space.roomy) {
            ZStack {
                if state.milestone != nil {
                    Circle().strokeBorder(accent, lineWidth: 2)
                    CheckMark()
                        .trim(from: 0, to: draw)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .padding(9)
                } else {
                    HeroMark(size: 36)
                }
            }
            .frame(width: 36, height: 36)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Design.Ink.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .id(text)
                .transition(.opacity)
            Spacer(minLength: 0)
        }
        .animation(Design.Motion.animation(.easeInOut(duration: 0.3)), value: text)
        .padding(.horizontal, Design.Space.loose)
        .padding(.vertical, Design.Space.roomy)
        .frame(width: captionWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
            .fill(Design.Retro.bg.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: Design.Stroke.hairline))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
        .opacity(text.isEmpty ? 0 : 1)
        .position(x: home.x + captionWidth / 2, y: home.y + 32)
        .animation(Design.Motion.animation(.spring(response: 0.6, dampingFraction: 0.88)), value: state.geometry.expanded)
        .transition(.opacity)
        .accessibilityIdentifier("visor.takeover.caption")
    }

    // MARK: Finale

    private var finaleSheet: some View {
        let keys: [(String, String)] = [
            (ShortcutSettings.hint(.toggle), "summon · put away"),
            (ShortcutSettings.hint(.hud), "expand to the HUD"),
            (ShortcutSettings.hint(.dictate), "dictate anywhere"),
            ("⌘.", "stop a reply"),
        ]
        return VStack(alignment: .leading, spacing: Design.Space.wide) {
            Text("That's Visor.")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
            Text("Everything lives in the notch. These bring it to you.")
                .font(Design.Typography.body())
                .foregroundStyle(Design.Ink.secondary)
            HStack(spacing: Design.Space.roomy) {
                ForEach(keys, id: \.0) { key, label in
                    VStack(spacing: Design.Space.normal) {
                        Text(key)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Design.Ink.primary)
                            .padding(.horizontal, Design.Space.roomy).frame(height: 34)
                            .raised(Design.Radius.control, strong: true, stroke: Design.Stroke.control)
                        Text(label).font(Design.Typography.caption()).foregroundStyle(Design.Ink.tertiary)
                    }
                }
            }
            HStack {
                Spacer()
                ActionChip(title: "Finish", prominent: true, action: actions.finish)
                    .accessibilityIdentifier("visor.takeover.finish")
            }
        }
        .accessibilityIdentifier("visor.takeover.finale")
    }

    // MARK: Chrome

    /// Skip, and the voice and sound switches, at the top right. No dots,
    /// no counts: the line along the bottom is the only progress.
    private func topBar(size: CGSize) -> some View {
        HStack(spacing: Design.Space.normal) {
            IconButton(symbol: narrator.voiceOn ? "waveform" : "waveform.slash",
                       tint: narrator.voiceOn ? Design.Ink.primary : Design.Ink.tertiary,
                       help: narrator.voiceOn ? "Mute the voice" : "Unmute the voice") { narrator.voiceOn.toggle() }
                .accessibilityIdentifier("visor.takeover.voice")
            IconButton(symbol: narrator.soundOn ? "speaker.wave.2" : "speaker.slash",
                       tint: narrator.soundOn ? Design.Ink.primary : Design.Ink.tertiary,
                       help: narrator.soundOn ? "Mute sounds" : "Unmute sounds") { narrator.soundOn.toggle() }
                .accessibilityIdentifier("visor.takeover.sound")
            ActionChip(title: state.step == .finale ? "Close" : "Skip", action: actions.skip)
                .accessibilityIdentifier("visor.takeover.skip")
        }
        .padding(.horizontal, Design.Space.roomy)
        .frame(height: 40)
        .background(Capsule().fill(Design.Retro.bg.opacity(0.7)))
        .position(x: size.width - 110, y: 48)
        .opacity(appeared ? 1 : 0)
    }

    private func progressBar(size: CGSize) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.10))
            Rectangle().fill(accent).frame(width: size.width * state.progress)
                .animation(Design.Motion.animation(.easeInOut(duration: 0.8)), value: state.progress)
        }
        .frame(width: size.width, height: 2)
        .position(x: size.width / 2, y: size.height - 1)
        .opacity(state.step == .intro ? 0 : 1)
        .accessibilityHidden(true)
    }
}

// MARK: - The one card

/// The single dark card the tour ever shows: centred, calm, no kicker,
/// no dots, no glow.
private struct TourCard<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(Design.Space.section + 4)
            .frame(width: width, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(Design.Retro.bg.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: Design.Stroke.hairline))
            .shadow(color: .black.opacity(0.55), radius: 36, y: 14)
            .accessibilityIdentifier("visor.takeover.card")
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
        VStack(alignment: .leading, spacing: Design.Space.wide) {
            Text("Your agent")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)

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

            HStack {
                Spacer()
                ActionChip(title: state.creating ? "Creating…" : "Create \(state.agentName.trimmingCharacters(in: .whitespaces).isEmpty ? "agent" : state.agentName)",
                           prominent: true, action: create)
                    .disabled(!state.canCreate)
                    .opacity(state.canCreate ? 1 : 0.5)
                    .accessibilityIdentifier("visor.takeover.create")
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = .name } }
    }
}

// MARK: - Video

/// The welcome video, played through an `AVPlayerLayer`. Reports progress
/// for the thin bar beneath it and says when it ends.
struct VideoIntro: NSViewRepresentable {
    let url: URL
    @Binding var progress: Double
    var muted: Bool
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVPlayer(url: url)
        player.isMuted = muted
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        let c = context.coordinator
        c.player = player
        c.observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { t in
            guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
            c.onProgress?(min(1, t.seconds / d))
        }
        c.onProgress = { progress = $0 }
        c.ended = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in c.onEnd?() }
        c.onEnd = onEnd
        player.play()
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        context.coordinator.player?.isMuted = muted
        context.coordinator.onEnd = onEnd
        context.coordinator.onProgress = { progress = $0 }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        if let o = coordinator.observer { coordinator.player?.removeTimeObserver(o) }
        if let e = coordinator.ended { NotificationCenter.default.removeObserver(e) }
    }

    final class Coordinator {
        var player: AVPlayer?
        var observer: Any?
        var ended: NSObjectProtocol?
        var onEnd: (() -> Void)?
        var onProgress: ((Double) -> Void)?
    }

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
            playerLayer.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}

// MARK: - The mark

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
            .shadow(color: Design.Retro.accent.opacity(0.4), radius: size * 0.14)
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

// MARK: - Scrim and strokes

/// The screen minus the card, for an even-odd fill. The card hole is the
/// card's rect scaled about its top centre — the same transform as the
/// card's own scale transition — and the scale is the animatable value,
/// so the hole and the card share one motion.
struct Scrim: Shape {
    var card: CGRect
    var scale: CGFloat

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
        return path
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
