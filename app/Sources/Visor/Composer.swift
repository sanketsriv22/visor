import SwiftUI

/// The message composer — one control, drawn at two densities.
///
/// Modelled on ChatGPT's composer, which is the one most people have in
/// their hands every day: a soft pill with the text on top at reading size
/// and a row of round 36-point controls underneath — a plus for everything
/// optional on the left, the microphone and the send circle on the right.
/// Proportions are ChatGPT's (16pt text with 1.5 line height, 36pt buttons,
/// 8pt gutters, 28pt radius) scaled down a notch for the card and kept as
/// is in the HUD. Visor's one addition is the model chip next to the plus,
/// because here the model is a per-message choice.
///
/// The send circle is the one filled, coloured thing in the card — the
/// theme accent, so purple on Midnight Purple and white on Mono (which is
/// exactly ChatGPT's white-on-dark). It becomes a stop square while a reply
/// streams.
///
/// The NSTextView stays underneath: native selection, undo and IME are the
/// reason it isn't a SwiftUI `TextField`.
struct Composer: View {
    @ObservedObject var chat: ChatController
    var layout: ChatSurface

    @State private var draftHeight: CGFloat = 24
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            field
            controls
        }
        .padding(.top, metrics.paddingTop)
        .padding(.bottom, metrics.paddingBottom)
        .padding(.horizontal, metrics.paddingSide)
        .background(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            .fill(Color.white.opacity(metrics.fill)))
        .overlay(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            .strokeBorder(Color.white.opacity(focused ? 0.16 : 0.09), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.28), radius: 10, y: 3)
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityIdentifier("visor.composer")
    }

    // MARK: Field

    private var field: some View {
        ZStack(alignment: .topLeading) {
            if chat.draft.isEmpty {
                Text(placeholder)
                    .font(.system(size: metrics.fontSize))
                    .foregroundStyle(.white.opacity(0.45))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .padding(.top, metrics.lineInset)
            }
            ComposerField(text: $chat.draft, onSubmit: chat.send, onHeightChange: { height in
                // Clamped here rather than in the field: the field
                // measures, the composer decides how much room to give.
                let clamped = min(max(height, metrics.minHeight), metrics.maxHeight)
                if abs(clamped - draftHeight) > 0.5 { draftHeight = clamped }
            }, fontSize: metrics.fontSize, lineSpacing: metrics.lineSpacing,
               onFocusChange: { focused = $0 })
            .accessibilityIdentifier("visor.composer.field")
        }
        .frame(height: max(draftHeight, metrics.minHeight))
        .animation(.easeOut(duration: 0.12), value: draftHeight)
        .padding(.horizontal, metrics.textInset)
    }

    private var placeholder: String {
        if chat.chatAgents.isEmpty { return "Add an agent in Settings to start" }
        return "Ask \(chat.agent?.name ?? "anything")"
    }

    // MARK: Controls

    /// Left: the plus (reasoning, speed — everything optional) and the model
    /// chip. Right: the microphone and send. Same order as ChatGPT so hands
    /// already know where things are.
    private var controls: some View {
        HStack(spacing: metrics.gap) {
            // Only for hosted agents: a local CLI agent picks its model
            // through its own arguments, so offering OpenRouter's catalogue
            // was a control that silently did nothing. Gated once, here, for
            // both faces.
            if chat.agent?.isChat ?? false {
                ComposerOptions(chat: chat)
                    .accessibilityIdentifier("visor.composer.options")
                InlineModelPicker(chat: chat)
                    .accessibilityIdentifier("visor.composer.model")
            } else if chat.isCLIAgent {
                CLIModelPicker(chat: chat)
                    .accessibilityIdentifier("visor.composer.model")
            }

            Spacer(minLength: 0)

            if chat.isStreaming {
                HStack(spacing: 6) {
                    DotMatrixIndicator(size: metrics.button * 0.34, tint: Design.Retro.accent)
                    Text("Streaming")
                        .font(.system(size: metrics.chipFont - 1, weight: .medium))
                        .foregroundStyle(Design.Ink.tertiary)
                }
                .padding(.trailing, 4)
                .transition(.opacity)
            }

            DictationControl(voice: chat.voice, onToggle: chat.toggleDictation,
                             size: metrics.button, circular: true)
                .accessibilityIdentifier("visor.composer.dictate")

            sendButton
        }
        .frame(height: metrics.button)
        .animation(.easeOut(duration: 0.15), value: chat.isStreaming)
    }

    @ViewBuilder
    private var sendButton: some View {
        let button = Button(action: chat.isStreaming ? chat.stop : chat.send) {
            ZStack {
                Circle().fill(sendFill)
                if chat.isStreaming {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Design.Retro.onAccent)
                        .frame(width: metrics.button * 0.34, height: metrics.button * 0.34)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: metrics.button * 0.5, weight: .bold))
                        .foregroundStyle(canSend ? Design.Retro.onAccent : Color.white.opacity(0.3))
                }
            }
            .frame(width: metrics.button, height: metrics.button)
            .contentShape(Circle())
        }
        .buttonStyle(.visorBare)
        .focusable(false)
        .disabled(!chat.isStreaming && !canSend)
        .accessibilityIdentifier(chat.isStreaming ? "visor.composer.stop" : "visor.composer.send")
        .help(chat.isStreaming ? "Stop the reply — ⌘." : "Send — ↩ (⇧↩ for a new line)")
        .animation(.easeOut(duration: 0.15), value: canSend)

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
        return Color.white.opacity(0.1)
    }

    private var canSend: Bool {
        !chat.isStreaming
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var metrics: Metrics { Metrics(layout) }

    /// ChatGPT's numbers, and the card's scaled copy of them.
    private struct Metrics {
        let fontSize: CGFloat
        /// Extra leading between lines: ChatGPT sets 24px on 16px type.
        let lineSpacing: CGFloat
        /// Where the placeholder's baseline sits so it matches the field.
        let lineInset: CGFloat
        let minHeight: CGFloat
        /// Lines, then it scrolls: enough to see what you're writing without
        /// the composer eating the transcript it belongs to.
        let maxHeight: CGFloat
        let textInset: CGFloat
        let rowGap: CGFloat
        let gap: CGFloat
        let button: CGFloat
        let chipFont: CGFloat
        let paddingTop: CGFloat
        let paddingBottom: CGFloat
        let paddingSide: CGFloat
        let radius: CGFloat
        let fill: Double

        init(_ layout: ChatSurface) {
            switch layout {
            case .compact:
                fontSize = 14; lineSpacing = 5; lineInset = 0
                minHeight = 22; maxHeight = 84
                textInset = 8; rowGap = 6; gap = 6
                button = 32; chipFont = 13
                paddingTop = 12; paddingBottom = 8; paddingSide = 8
                radius = 24; fill = 0.09
            case .hud:
                fontSize = 16; lineSpacing = 8; lineInset = 0
                minHeight = 24; maxHeight = 168
                textInset = 8; rowGap = 8; gap = 8
                button = 36; chipFont = 14
                paddingTop = 14; paddingBottom = 8; paddingSide = 8
                radius = 28; fill = 0.09
            }
        }
    }
}
