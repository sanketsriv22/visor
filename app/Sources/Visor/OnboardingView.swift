import AppKit
import SwiftUI

extension Notification.Name {
    /// Show the introduction again — from the menu-bar panel.
    static let visorReplayIntroduction = Notification.Name("visor.replayIntroduction")
}

/// The window the introduction lives in. One place, so the app and the
/// Design Lab build exactly the same thing and a capture of it is a capture
/// of what the user sees.
@MainActor
enum OnboardingWindow {
    static let size = CGSize(width: 560, height: 520)

    static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Welcome to Visor"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: VisorTheme.current.isDark ? .darkAqua : .aqua)
        window.backgroundColor = NSColor(Design.Retro.bg)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()
        return window
    }

    /// Host the view at the window's full content size. Sizing options are
    /// cleared so the hosting view never resizes the window to the view's
    /// ideal size (or the reverse) — the SwiftUI layout fills what it's given.
    static func fill(_ window: NSWindow, with view: OnboardingView) {
        let host = NSHostingView(rootView: view.frame(minWidth: size.width, minHeight: size.height))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
    }
}

/// The first-launch introduction.
///
/// A notch app disappears by design, so the one thing this has to teach —
/// before anything else, and again at the end — is how to get Visor back.
/// Everything else is a single card per idea: capture a note, bring an
/// agent, expand into the HUD, and which permissions will be asked for when
/// a feature first needs them (none are requested here).
///
/// Themed like the menu-bar panel: this is the second thing most people see.
struct OnboardingView: View {
    let shortcut: String
    let onShowNotch: () -> Void
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    @State private var step: Int

    init(step: Int = 0, shortcut: String,
         onShowNotch: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        _step = State(initialValue: min(max(step, 0), Self.pages.count - 1))
        self.shortcut = shortcut
        self.onShowNotch = onShowNotch
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
    }

    private struct Page {
        let glyph: String
        let kicker: String
        let title: String
        let body: String
        let action: Action?
        enum Action { case showNotch, openSettings }
    }

    private static let pages: [Page] = [
        Page(glyph: Glyph.open, kicker: "01 · THE NOTCH",
             title: "Visor lives in your notch.",
             body: "Click the notch, or press the summon key, and a card slides out from behind it. Click the notch again, or press Esc, and it goes back. That's the whole idea: a surface that's always there and never in the way.",
             action: .showNotch),
        Page(glyph: Glyph.check, kicker: "02 · NOTES",
             title: "Start with a note.",
             body: "The first face is a note. Type a task and press Return for the next; click the circle to complete it. On disk it's plain Markdown in ~/Documents/Visor, so your agents can read and write the same file.",
             action: nil),
        Page(glyph: Glyph.agents, kicker: "03 · AGENTS",
             title: "Bring an agent when you're ready.",
             body: "Chat talks to any model through OpenRouter with a key, or to a command-line agent already on your Mac — Claude Code, Codex, Devin. You name each one; the name is what you'll see in the notch.",
             action: .openSettings),
        Page(glyph: Glyph.hud, kicker: "04 · CHAT AND HUD",
             title: "Talk in the card. Expand when it gets serious.",
             body: "Replies stream into the card with real headings, lists and code. When a conversation outgrows it, expand into the HUD: the same chat at full-screen scale, with rails for your agents, tasks and memory. Esc brings it back down.",
             action: nil),
        Page(glyph: Glyph.dictate, kicker: "05 · WHEN ASKED",
             title: "Permissions come later, one at a time.",
             body: "Dictation will ask for the microphone the first time you use it. Computer Use will ask for Accessibility and Screen Recording when you first run a task. Nothing is requested now.",
             action: nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
            summon
            footer
        }
        .padding(28)
        .background(Design.Retro.bg)
        .tint(Design.Retro.accent)
        .environment(\.colorScheme, VisorTheme.current.isDark ? .dark : .light)
        .accessibilityIdentifier("visor.onboarding")
    }

    private var page: Page { Self.pages[step] }

    private var header: some View {
        HStack(spacing: 10) {
            BeamMark().frame(width: 18, height: 16)
            Text("VISOR")
                .font(.custom(Design.Text.face, size: 14)).tracking(3)
                .foregroundStyle(Design.Retro.text)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<Self.pages.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i == step ? Design.Retro.accent : Design.Retro.line)
                        .frame(width: i == step ? 18 : 8, height: 3)
                        .animation(.easeOut(duration: 0.18), value: step)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RetroIcon(page.glyph, size: 18, color: Design.Retro.accent)
                Text(page.kicker)
                    .font(Design.Text.f(10)).tracking(1.5)
                    .foregroundStyle(Design.Retro.dim)
            }
            Text(page.title)
                .font(Design.Text.f(24, weight: .semibold))
                .foregroundStyle(Design.Retro.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(page.body)
                .font(Design.Text.f(13))
                .foregroundStyle(Design.Retro.dim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let action = page.action {
                Button {
                    switch action {
                    case .showNotch:    onShowNotch()
                    case .openSettings: onOpenSettings()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(action == .showNotch ? "Show me the notch" : "Open Settings → Agents")
                            .font(Design.Text.f(12, weight: .medium))
                        Text("→").font(Design.Text.f(12))
                    }
                    .foregroundStyle(Design.Retro.accent)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: Design.Retro.radius)
                        .fill(Design.Retro.accentDim))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.visor)
                .accessibilityIdentifier("visor.onboarding.action")
                .padding(.top, 4)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Retro.radius + 3)
            .fill(Design.Retro.panel))
        .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius + 3)
            .stroke(Design.Retro.line, lineWidth: 1))
        .id(step)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.16), value: step)
    }

    /// Always on screen, on every page: the answer to "where did it go?"
    private var summon: some View {
        HStack(spacing: 10) {
            RetroIcon(Glyph.open, size: 11, color: Design.Retro.dim)
            Text("Get Visor back any time:")
                .font(Design.Text.f(11))
                .foregroundStyle(Design.Retro.dim)
            Text(shortcut)
                .font(Design.Text.mono)
                .foregroundStyle(Design.Retro.text)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Design.Retro.radius)
                    .fill(Design.Retro.panelDeep))
            Text("or the")
                .font(Design.Text.f(11))
                .foregroundStyle(Design.Retro.dim)
            BeamMark().frame(width: 13, height: 11)
            Text("in the menu bar.")
                .font(Design.Text.f(11))
                .foregroundStyle(Design.Retro.dim)
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
        .accessibilityIdentifier("visor.onboarding.summon")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Skip", action: onDone)
                .buttonStyle(.visorBare)
                .font(Design.Text.f(11))
                .foregroundStyle(Design.Retro.faint)
                .accessibilityIdentifier("visor.onboarding.skip")
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.visor)
                    .font(Design.Text.f(12))
                    .foregroundStyle(Design.Retro.dim)
                    .accessibilityIdentifier("visor.onboarding.back")
            }
            Button {
                if step < Self.pages.count - 1 { step += 1 } else { onDone() }
            } label: {
                Text(step < Self.pages.count - 1 ? "Next" : "Done")
                    .font(Design.Text.f(12, weight: .semibold))
                    .foregroundStyle(Design.Retro.bg)
                    .padding(.horizontal, 16).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: Design.Retro.radius)
                        .fill(Design.Retro.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.visorBare)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("visor.onboarding.next")
        }
    }
}
