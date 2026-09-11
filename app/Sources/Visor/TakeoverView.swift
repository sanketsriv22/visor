import AppKit
import AVFoundation
import SwiftUI

/// The introduction's overlay: the welcome video, or the mark rising out
/// of the notch; one caption that follows the voice, its mark breathing
/// with the sound; rings of that sound spreading from the notch when a
/// moment lands; a reticle that locks onto the real control to press,
/// with a leader line back to the caption; a single centred card for the
/// one form and the goodbye; a thin line of progress along the bottom.
/// The dark sheet behind the product is a separate window beneath the
/// notch's (see `TakeoverGuide`), so this view draws nothing over the card
/// and lets clicks through wherever it draws nothing at all.
struct TakeoverView: View {
    @ObservedObject var state: TakeoverState
    @ObservedObject private var narrator: Narrator
    @ObservedObject private var spotlight = Spotlight.shared
    var actions: TakeoverActions

    @State private var appeared = false
    @State private var draw: CGFloat = 0
    @State private var videoProgress: Double = 0
    @State private var lockedID: String? = nil

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
            let target = target(size: size)

            ZStack(alignment: .topLeading) {
                NotchGlow(meter: narrator.meter, origin: origin, width: notchRect.width)
                    .allowsHitTesting(false)

                if let target {
                    Targeting(target: target, from: captionRect(size: size), draw: draw)
                        .id(target.id)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                if state.step == .intro {
                    intro(size: size, origin: origin)
                } else {
                    caption(size: size)
                        .allowsHitTesting(false)
                }

                if state.step == .agent, state.formVisible, !state.created {
                    TourCard(width: 420) { AgentForm(state: state, create: actions.createAgent) }
                        .reportHit()
                        .position(x: size.width / 2, y: cardHome(size: size))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                if state.step == .finale, state.sheetVisible {
                    TourCard(width: 560) { finaleSheet }
                        .reportHit()
                        .position(x: size.width / 2, y: cardHome(size: size))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                topBar(size: size)
                progressBar(size: size)
                    .allowsHitTesting(false)
            }
            .animation(Design.Motion.animation(.easeInOut(duration: 0.35)), value: target?.id)
            .animation(Design.Motion.animation(.linear(duration: 0.06)), value: target?.rect)
            .onPreferenceChange(HitRectsKey.self) { state.hitRects = $0 }
            .frame(width: size.width, height: size.height)
            .onChange(of: state.step) { _ in redraw() }
            .onChange(of: target?.id) { _ in redraw() }
            .onAppear {
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

    // MARK: Coordinates

    /// Screen rect (origin bottom-left) → this view's (origin top-left).
    private func view(_ r: CGRect) -> CGRect {
        let b = state.geometry.bounds
        return CGRect(x: r.minX - b.minX, y: b.maxY - r.maxY, width: r.width, height: r.height)
    }

    private var card: CGRect { view(state.geometry.card) }
    private var notchRect: CGRect { view(state.geometry.notch) }
    private var notchH: CGFloat { notchRect.height }

    /// Where the one tour card sits: centred in the room below the notch
    /// card, never over it.
    private func cardHome(size: CGSize) -> CGFloat {
        let below = state.geometry.expanded ? card.maxY : notchRect.maxY
        return max(size.height * 0.5, below + 40 + 190)
    }

    /// Wide enough to read at 17pt, never wider than the room beside the
    /// card: on a 14-inch screen that room is about 440pt.
    private var captionWidth: CGFloat {
        if state.geometry.hud { return 320 }
        if state.geometry.expanded {
            let room = state.geometry.bounds.width - card.maxX - 72
            return max(360, min(520, room))
        }
        return 520
    }
    private let captionHeight: CGFloat = 76

    /// Which of the caption's homes is in use; changing it crossfades the
    /// caption rather than flying it.
    private var captionPlace: Int { state.geometry.hud ? 2 : (state.geometry.expanded ? 1 : 0) }

    /// The caption's home: under the notch until the card opens, then beside
    /// the card; in the HUD, the empty bottom of the left rail, clear of the
    /// conversation. One place per moment, no hopping.
    private func captionHome(size: CGSize) -> CGPoint {
        let w = captionWidth
        if state.geometry.hud {
            return CGPoint(x: 32, y: size.height - 150)
        }
        if state.geometry.expanded {
            return CGPoint(x: min(card.maxX + 40, size.width - w - 32), y: card.minY + notchH + 72)
        }
        return CGPoint(x: size.width / 2 - w / 2, y: notchRect.maxY + 130)
    }

    private func captionRect(size: CGSize) -> CGRect {
        CGRect(origin: captionHome(size: size), size: CGSize(width: captionWidth, height: captionHeight))
    }

    // MARK: Targets

    /// A real control the tour wants pressed, where it actually is.
    struct Target: Equatable {
        var id: String
        var rect: CGRect
        var label: String
    }

    /// The control's frame, from the registry of real controls (or the
    /// lab's stand-in), in this view's coordinates.
    private func frame(of id: String) -> CGRect? {
        if let override = state.spotlightOverride { return override[id] }
        return spotlight.frames[id].map(view)
    }

    private func target(size: CGSize) -> Target? {
        switch state.step {
        case .notch where !state.geometry.expanded:
            return Target(id: "notch", rect: notchRect.insetBy(dx: -14, dy: -6), label: "THE NOTCH")
        case .task where state.awaitingApproval:
            return frame(of: "allow").map { Target(id: "allow", rect: $0, label: "ALLOW") }
        case .drive where state.askStop:
            return frame(of: "stop").map { Target(id: "stop", rect: $0, label: "STOP") }
        default:
            return nil
        }
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
                BreathingMark(meter: narrator.meter, size: 220)
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
            .allowsHitTesting(false)
            .accessibilityIdentifier("visor.takeover.intro")
        }
    }

    // MARK: Caption

    /// The voice, written down: the mark, breathing with the sound, and the
    /// line it is saying. When something lands, the mark becomes a check
    /// for a moment.
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
                    BreathingMark(meter: narrator.meter, size: 40)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(text)
                    .transition(.opacity)
                if let detail = narrator.detail, state.milestone == nil {
                    Text(detail)
                        .font(Design.Typography.caption())
                        .foregroundStyle(Design.Ink.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(Design.Motion.animation(.easeInOut(duration: 0.3)), value: text)
        .animation(Design.Motion.animation(.easeInOut(duration: 0.3)), value: narrator.detail)
        .padding(.horizontal, Design.Space.section)
        .padding(.vertical, Design.Space.loose)
        .frame(width: captionWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
            .fill(Design.Retro.bg.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: Design.Stroke.hairline))
        .shadow(color: .black.opacity(0.5), radius: 28, y: 10)
        .opacity(text.isEmpty ? 0 : 1)
        .position(x: home.x + captionWidth / 2, y: home.y + captionHeight / 2)
        .id(captionPlace)
        .transition(.opacity.animation(Design.Motion.animation(.easeInOut(duration: 0.4))))
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
        .reportHit()
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

// MARK: - Click ownership

/// The frames the overlay owns clicks in, gathered from the card and the
/// chrome. `.global` in the overlay's hosting view is its own top-left
/// space, which is what `TakeoverHostingView.hitTest` compares against.
struct HitRectsKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    func reportHit() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: HitRectsKey.self, value: [g.frame(in: .global)])
        })
    }
}

// MARK: - Targeting

/// A reticle that locks onto the control to press: four corner brackets
/// that arrive from slightly outside and settle on it, and a leader line
/// back to the caption with a dot at each end. No readout — it would sit
/// on the product's own text; the caption says what to press.
private struct Targeting: View {
    let target: TakeoverView.Target
    let from: CGRect
    let draw: CGFloat
    @State private var locked = false

    private var accent: Color { Design.Retro.accent }

    var body: some View {
        let rect = target.rect.insetBy(dx: -8, dy: -6)
        let anchor = nearestEdgePoint(of: rect, to: from)
        let start = leaderStart(from: from, to: anchor)
        ZStack(alignment: .topLeading) {
            // Drawn in its own frame so the lock-on scales about its centre.
            Brackets(rect: CGRect(origin: .zero, size: rect.size), arm: min(14, rect.width / 3))
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: accent.opacity(0.6), radius: 6)
                .frame(width: rect.width, height: rect.height)
                .scaleEffect(locked ? 1 : 1.35)
                .opacity(locked ? 1 : 0)
                .position(x: rect.midX, y: rect.midY)

            Leader(from: start, to: anchor)
                .trim(from: 0, to: draw)
                .stroke(accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            Circle().fill(accent).frame(width: 5, height: 5).position(start).opacity(draw > 0.05 ? 1 : 0)
            Circle().fill(accent).frame(width: 5, height: 5).position(anchor).opacity(draw > 0.95 ? 1 : 0)
        }
        .onAppear {
            withAnimation(Design.Motion.animation(.spring(response: 0.5, dampingFraction: 0.7))) { locked = true }
        }
    }

    private func nearestEdgePoint(of rect: CGRect, to other: CGRect) -> CGPoint {
        let c = CGPoint(x: other.midX, y: other.midY)
        let x = min(max(c.x, rect.minX), rect.maxX)
        let y = min(max(c.y, rect.minY), rect.maxY)
        // Snap to the nearest side, a little outside it.
        let dl = abs(x - rect.minX), dr = abs(x - rect.maxX), dt = abs(y - rect.minY), db = abs(y - rect.maxY)
        let m = min(dl, dr, dt, db)
        if m == dr { return CGPoint(x: rect.maxX + 10, y: rect.midY) }
        if m == dl { return CGPoint(x: rect.minX - 10, y: rect.midY) }
        if m == db { return CGPoint(x: rect.midX, y: rect.maxY + 10) }
        return CGPoint(x: rect.midX, y: rect.minY - 10)
    }

    private func leaderStart(from rect: CGRect, to: CGPoint) -> CGPoint {
        if to.y < rect.minY { return CGPoint(x: rect.midX, y: rect.minY - 8) }
        if to.x < rect.minX { return CGPoint(x: rect.minX - 8, y: rect.midY) }
        if to.x > rect.maxX { return CGPoint(x: rect.maxX + 8, y: rect.midY) }
        return CGPoint(x: rect.midX, y: rect.maxY + 8)
    }
}

/// Four corner brackets around a rect.
private struct Brackets: Shape {
    let rect: CGRect
    let arm: CGFloat

    func path(in _: CGRect) -> Path {
        var p = Path()
        let r = rect
        // top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + arm)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + arm, y: r.minY))
        // top-right
        p.move(to: CGPoint(x: r.maxX - arm, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + arm))
        // bottom-right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - arm)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - arm, y: r.maxY))
        // bottom-left
        p.move(to: CGPoint(x: r.minX + arm, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - arm))
        return p
    }
}

/// A leader line with one bend: straight out from the caption, then to
/// the target — the way a diagram labels a part.
private struct Leader: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        let dx = to.x - from.x, dy = to.y - from.y
        if abs(dx) > abs(dy) {
            let bend = CGPoint(x: to.x - (dx > 0 ? 1 : -1) * min(40, abs(dx) / 2), y: from.y)
            p.addLine(to: bend)
            p.addLine(to: to)
        } else {
            let bend = CGPoint(x: from.x, y: to.y - (dy > 0 ? 1 : -1) * min(40, abs(dy) / 2))
            p.addLine(to: bend)
            p.addLine(to: to)
        }
        return p
    }
}

// MARK: - Sound made visible

/// A soft light under the notch that breathes with the voice — the sound
/// has a place it comes from.
private struct NotchGlow: View {
    @ObservedObject var meter: VoiceMeter
    let origin: CGPoint
    let width: CGFloat

    var body: some View {
        Ellipse()
            .fill(RadialGradient(colors: [MarkColor.glow.opacity(0.32), MarkColor.glow.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: width * 0.9))
            .frame(width: width * 2.4, height: width * 0.9)
            .position(x: origin.x, y: origin.y - 4)
            .opacity(0.15 + Double(meter.level) * 0.85)
            .scaleEffect(0.85 + meter.level * 0.35, anchor: .top)
            .blendMode(.screen)
    }
}

/// The mark's own colour: it is rendered purple whatever the theme, so
/// its glow is too — on Mono the theme accent is white, and a white halo
/// read as a circle drawn around it.
enum MarkColor {
    static let glow = Color(red: 0.58, green: 0.40, blue: 0.94)
}

/// The mark with a halo that swells with the voice.
struct BreathingMark: View {
    @ObservedObject var meter: VoiceMeter
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [MarkColor.glow.opacity(0.45), MarkColor.glow.opacity(0)],
                                     center: .center, startRadius: size * 0.15, endRadius: size * 0.9))
                .frame(width: size * 1.8, height: size * 1.8)
                .scaleEffect(0.6 + meter.level * 0.6)
                .opacity(0.2 + Double(meter.level) * 0.8)
            HeroMark(size: size)
                .scaleEffect(1 + meter.level * 0.06)
        }
        .frame(width: size, height: size)
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
        // A video that can't load hands over to the tour instead of holding it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak player] in
            if player?.currentItem?.status == .failed { c.onEnd?() }
        }
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

/// The mark: the Blender-rendered trefoil turning once every six seconds,
/// or the flat BeamMark if the sheet isn't bundled. Bobs gently so it
/// reads as alive, not pasted.
struct HeroMark: View {
    var size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / HeroSheet.fps, paused: Design.Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let bob = Design.Motion.reduced ? 0 : sin(t * 1.2) * size * 0.03
            Group {
                if let sheet = HeroSheet.image {
                    HeroSheet.frame(sheet, index: Int(t * HeroSheet.fps) % HeroSheet.count, size: size)
                } else {
                    BeamMark()
                        .frame(width: size * 0.7, height: size * 0.62)
                        .foregroundStyle(Design.Retro.accent)
                }
            }
            .offset(y: bob)
            .shadow(color: MarkColor.glow.opacity(0.3), radius: size * 0.12)
        }
        .frame(width: size, height: size)
    }
}

/// The turntable sprite sheet: 90 frames of the trefoil in a 10×9 grid —
/// one turn with a slow nod, rendered in Blender (see docs/design-lab.md)
/// and played at 15 frames a second, so a turn takes six seconds. Loaded once.
enum HeroSheet {
    static let count = 90
    static let columns = 10
    static let fps: Double = 15
    static let cell: CGFloat = 256
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

private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return p
    }
}
