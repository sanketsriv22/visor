import SwiftUI

/// The message composer — one control, drawn at two densities.
///
/// The notch card and the HUD each assembled their own: the card measured
/// its text and grew to three lines, the HUD sat on a fixed 66-point field,
/// and each laid out its own row of pickers. Two composers for one draft is
/// two places to get every rule right, and the gating of the model picker
/// had already drifted between them once.
///
/// The look follows the composers people already know from ChatGPT, Claude
/// and Cursor: a raised, softly bordered field that lights up when it has
/// focus; the model as a chip; every other option folded behind one
/// control; and a send button that is the one filled, coloured thing in the
/// card — the theme accent, so on Midnight Purple it's purple and on Mono
/// it's white. Nothing here is orange any more.
///
/// The NSTextView stays underneath: native selection, undo and IME are the
/// reason it isn't a SwiftUI `TextField`.
struct Composer: View {
    @ObservedObject var chat: ChatController
    var layout: ChatSurface

    @State private var draftHeight: CGFloat = 16
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            field
            controls
        }
        .padding(.horizontal, metrics.paddingH)
        .padding(.top, metrics.paddingV)
        .padding(.bottom, metrics.paddingV - 2)
        .background(surface)
        .overlay(border)
        // A soft accent halo while the field has focus: the cheapest way to
        // say "this is where your typing goes" in a panel that is never the
        // active app's key window for long.
        .shadow(color: Design.Retro.accent.opacity(focused ? 0.22 : 0),
                radius: focused ? 12 : 0, y: 2)
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityIdentifier("visor.composer")
    }

    // MARK: Field

    private var field: some View {
        ZStack(alignment: .topLeading) {
            if chat.draft.isEmpty {
                Text(placeholder)
                    .font(.system(size: metrics.fontSize))
                    .foregroundStyle(.white.opacity(0.32))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ComposerField(text: $chat.draft, onSubmit: chat.send, onHeightChange: { height in
                // Clamped here rather than in the field: the field
                // measures, the composer decides how much room to give.
                let clamped = min(max(height, metrics.minHeight), metrics.maxHeight)
                if abs(clamped - draftHeight) > 0.5 { draftHeight = clamped }
            }, fontSize: metrics.fontSize, onFocusChange: { focused = $0 })
            .accessibilityIdentifier("visor.composer.field")
        }
        .frame(height: max(draftHeight, metrics.minHeight))
        .animation(.easeOut(duration: 0.12), value: draftHeight)
        .padding(.top, 2)
    }

    private var placeholder: String {
        if chat.chatAgents.isEmpty { return "Add an agent in Settings to start…" }
        return "Message \(chat.agent?.name ?? "your agent")…"
    }

    // MARK: Controls

    /// The model belongs here, not two rows up: it's a decision you make
    /// about the message you're writing. Everything else folds behind the
    /// one options control.
    private var controls: some View {
        HStack(spacing: metrics.controlGap) {
            // Only for hosted agents: a local CLI agent picks its model
            // through its own arguments, so offering OpenRouter's catalogue
            // was a control that silently did nothing. Gated once, here, for
            // both faces.
            if chat.agent?.isChat ?? false {
                InlineModelPicker(chat: chat)
                    .accessibilityIdentifier("visor.composer.model")
                ComposerOptions(chat: chat)
                    .accessibilityIdentifier("visor.composer.options")
            } else if chat.isCLIAgent {
                CLIModelPicker(chat: chat)
                    .accessibilityIdentifier("visor.composer.model")
            }

            Spacer(minLength: 0)

            if chat.isStreaming {
                HStack(spacing: 5) {
                    DotMatrixIndicator(size: metrics.indicator, tint: Design.Retro.accent)
                    Text("Streaming")
                        .font(.system(size: metrics.hintSize, weight: .medium))
                        .foregroundStyle(Design.Ink.tertiary)
                }
                .transition(.opacity)
            } else if canSend {
                // Only once there's something to send, and only as a whisper.
                Text("↩")
                    .font(.system(size: metrics.hintSize, weight: .semibold))
                    .foregroundStyle(Design.Ink.faint)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            sendButton
        }
        .frame(height: metrics.controlHeight)
        .animation(.easeOut(duration: 0.15), value: chat.isStreaming)
        .animation(.easeOut(duration: 0.15), value: canSend)
    }

    @ViewBuilder
    private var sendButton: some View {
        let button = Button(action: chat.isStreaming ? chat.stop : chat.send) {
            ZStack {
                Circle().fill(sendFill)
                if chat.isStreaming {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Design.Retro.onAccent)
                        .frame(width: metrics.sendSize * 0.36, height: metrics.sendSize * 0.36)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: metrics.sendSize * 0.5, weight: .bold))
                        .foregroundStyle(canSend ? Design.Retro.onAccent : Color.white.opacity(0.35))
                }
            }
            .frame(width: metrics.sendSize, height: metrics.sendSize)
            .contentShape(Circle())
            .scaleEffect(canSend || chat.isStreaming ? 1 : 0.92)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: canSend)
        }
        .buttonStyle(.visorBare)
        .disabled(!chat.isStreaming && !canSend)
        .accessibilityIdentifier(chat.isStreaming ? "visor.composer.stop" : "visor.composer.send")
        .help(chat.isStreaming ? "Stop the reply — ⌘." : "Send — ↩ (⇧↩ for a new line)")

        // Exactly one recipient for the chord. The field itself sends on
        // Return, and the HUD's root is mounted at the same time as the card,
        // so only the compact face claims ⌘↩ / ⌘. — two views claiming a
        // shortcut is how you get one that fires twice.
        if layout == .compact {
            button.keyboardShortcut(chat.isStreaming ? "." : .return, modifiers: [.command])
        } else {
            button
        }
    }

    private var sendFill: Color {
        if chat.isStreaming || canSend { return Design.Retro.accent }
        return Color.white.opacity(0.08)
    }

    private var canSend: Bool {
        !chat.isStreaming
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Chrome

    private var surface: some View {
        RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            .fill(Color.white.opacity(focused ? 0.075 : 0.055))
    }

    /// A hairline that is brighter along the top than the bottom, which is
    /// what makes a flat dark panel read as raised rather than cut out.
    private var border: some View {
        RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: focused
                        ? [Design.Retro.accent.opacity(0.7), Design.Retro.accent.opacity(0.35)]
                        : [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
    }

    private var metrics: Metrics { Metrics(layout) }

    /// Every number the two densities disagree on, in one place.
    private struct Metrics {
        let fontSize: CGFloat
        let minHeight: CGFloat
        /// Lines, then it scrolls: enough to see what you're writing without
        /// the composer eating the transcript it belongs to.
        let maxHeight: CGFloat
        let rowGap: CGFloat
        let controlGap: CGFloat
        let controlHeight: CGFloat
        let sendSize: CGFloat
        let indicator: CGFloat
        let hintSize: CGFloat
        let paddingH: CGFloat
        let paddingV: CGFloat
        let radius: CGFloat

        init(_ layout: ChatSurface) {
            switch layout {
            case .compact:
                fontSize = 13; minHeight = 18; maxHeight = 54
                rowGap = 8; controlGap = 6; controlHeight = 26
                sendSize = 26; indicator = 11; hintSize = 10
                paddingH = 12; paddingV = 11
                radius = 14
            case .hud:
                fontSize = 15; minHeight = 22; maxHeight = 140
                rowGap = 12; controlGap = 8; controlHeight = 32
                sendSize = 32; indicator = 12; hintSize = 11
                paddingH = 16; paddingV = 14
                radius = Design.Radius.card
            }
        }
    }
}
