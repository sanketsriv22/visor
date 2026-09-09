import SwiftUI

/// The message composer — one control, drawn at two densities.
///
/// The notch card and the HUD each assembled their own: the card measured
/// its text and grew to three lines, the HUD sat on a fixed 66-point field,
/// and each laid out its own row of pickers. Two composers for one draft is
/// two places to get every rule right, and the gating of the model picker
/// had already drifted between them once.
///
/// Both faces now grow with the draft (to a limit that suits their size),
/// share the placeholder, the control row and the send/stop button, and
/// keep the NSTextView underneath — native selection, undo and IME are the
/// reason it isn't a SwiftUI `TextField`.
struct Composer: View {
    @ObservedObject var chat: ChatController
    var layout: ChatSurface

    @State private var draftHeight: CGFloat = 16

    var body: some View {
        VStack(spacing: metrics.rowGap) {
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text("Message \(chat.agent?.name ?? "your agent")…")
                        .font(.system(size: metrics.fontSize))
                        .foregroundStyle(.white.opacity(0.3))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ComposerField(text: $chat.draft, onSubmit: chat.send, onHeightChange: { height in
                    // Clamped here rather than in the field: the field
                    // measures, the composer decides how much room to give.
                    let clamped = min(max(height, metrics.minHeight), metrics.maxHeight)
                    if abs(clamped - draftHeight) > 0.5 { draftHeight = clamped }
                }, fontSize: metrics.fontSize)
                .accessibilityIdentifier("visor.composer.field")
            }
            .frame(height: max(draftHeight, metrics.minHeight))
            .animation(.easeOut(duration: 0.12), value: draftHeight)

            if layout == .hud {
                // A hairline between the message and its controls, so the
                // row of pickers reads as a toolbar for the field above
                // rather than a second thing floating in the same box.
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            }

            controls
        }
        .padding(.horizontal, metrics.paddingH)
        .padding(.vertical, metrics.paddingV)
        .background(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            .fill(metrics.fill))
        .overlay(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            .stroke(.white.opacity(0.09), lineWidth: 1))
        .accessibilityIdentifier("visor.composer")
    }

    /// The model belongs here, not two rows up: it's a decision you make
    /// about the message you're writing.
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

            if layout == .hud, chat.isStreaming {
                DotMatrixIndicator(size: 11)
                Text("working").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }

            Spacer(minLength: 0)

            sendButton
        }
        // Fixed, because a hosted agent shows three controls here and a CLI
        // agent shows one label — without this the whole composer changed
        // height as you switched between them.
        .frame(height: metrics.controlHeight)
    }

    @ViewBuilder
    private var sendButton: some View {
        let button = Button(action: chat.isStreaming ? chat.stop : chat.send) {
            Image(systemName: chat.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: metrics.sendSize))
                .foregroundStyle(chat.isStreaming
                                 ? Color.orange
                                 : (canSend ? metrics.sendOn : Color.white.opacity(0.22)))
                .frame(width: metrics.sendSize + 8, height: metrics.sendSize + 8)
                .contentShape(Rectangle())
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

    private var canSend: Bool {
        !chat.isStreaming
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        let sendOn: Color
        let paddingH: CGFloat
        let paddingV: CGFloat
        let radius: CGFloat
        let fill: Color

        init(_ layout: ChatSurface) {
            switch layout {
            case .compact:
                fontSize = 12; minHeight = 16; maxHeight = 48
                rowGap = 7; controlGap = 6; controlHeight = 20
                sendSize = 16; sendOn = Color.white.opacity(0.9)
                paddingH = 12; paddingV = 9
                radius = Design.Radius.panel; fill = Design.Surface.hover
            case .hud:
                fontSize = 15; minHeight = 22; maxHeight = 132
                rowGap = 12; controlGap = 8; controlHeight = 28
                sendSize = 24; sendOn = Color.white
                paddingH = 16; paddingV = 16
                radius = Design.Radius.card; fill = Design.Surface.raised
            }
        }
    }
}
