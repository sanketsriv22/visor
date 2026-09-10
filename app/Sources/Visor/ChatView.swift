import AppKit
import SwiftUI

/// The chat face of the notch: a transcript and a composer, in the same black
/// card the note uses so switching modes reads as one surface changing shape
/// rather than two different windows.
struct ChatCard: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var ai: AIRunner
    @ObservedObject private var accounts = CLIAccounts.shared
    /// Height of the notch the card tucks up behind.
    var topInset: CGFloat
    /// Width of the notch, so the band can flank it exactly as the note card's
    /// does — same geometry both sides means nothing shifts on a mode swap.
    var notchWidth: CGFloat
    var mode: VisorMode
    var onMode: (VisorMode) -> Void
    var onHUD: () -> Void
    var onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            notchBand
            agentBar
            Divider().overlay(Design.Surface.hairline)
            if chat.showingHistory {
                history
            } else {
                TranscriptView(chat: chat, layout: .compact) { emptyState }
                Composer(chat: chat, layout: .compact)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        // Chrome and size belong to StickyRootView, so the card morphs between
        // modes as one shape instead of cross-fading with the note card.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Escape steps back one level rather than always closing the notch:
        // from the chat list to the chat, and only then out.
        .onExitCommand {
            if chat.showingHistory {
                withAnimation(.easeInOut(duration: 0.18)) { chat.showingHistory = false }
            } else {
                onClose()
            }
        }
        .task { await chat.loadModels() }
    }

    // MARK: - Header

    /// Identical geometry to the note card's band — centred on the notch,
    /// fixed shoulders — so the switcher and the action icons occupy the same
    /// screen position in both faces and don't move on a swap.
    private var notchBand: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            // Against the notch, matching the note card — the shoulder is a
            // fixed width anchored to the notch, so anything at its outer end
            // floats free of the card edge once the card is wider.
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                // Reserved for the switcher the root draws.
                Color.clear.frame(width: ModeSwitcher.width, height: 1)
            }
            .frame(width: NotchController.shoulderWidth, alignment: .trailing)
            Spacer(minLength: 0)
                .frame(width: notchWidth + NotchController.notchClearance)
            // Four 24pt controls in the 106pt shoulder. One component, so
            // their targets, icon sizes and feedback agree.
            HStack(spacing: 0) {
                if chat.isStreaming {
                    IconButton(symbol: "stop.fill", size: Design.Metric.small,
                               tint: Design.Retro.accent,
                               help: "Stop the reply — this also stops it being billed",
                               action: chat.stop)
                        .accessibilityIdentifier("visor.chat.stop")
                }
                IconButton(symbol: "square.and.pencil", size: Design.Metric.small,
                           help: "New chat") { chat.newChat() }
                    .accessibilityIdentifier("visor.chat.new")
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: Design.Metric.small,
                           help: "Expand to HUD — \(ShortcutSettings.hint(.hud))", action: onHUD)
                    .accessibilityIdentifier("visor.chat.hud")
                overflowMenu.frame(width: Design.Metric.small, height: Design.Metric.small)
                    .accessibilityIdentifier("visor.chat.overflow")
                Spacer(minLength: 0)
            }
            .frame(width: NotchController.shoulderWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(height: topInset)
    }

    /// Who you're talking to and on what: the agent is the product, so its
    /// identity leads the card. One control — name, model, status — that
    /// opens the agent selector.
    private var agentBar: some View {
        HStack(spacing: Design.Space.normal) {
            AgentIdentity(chat: chat)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// What to say under an agent's name: the model for a hosted one, and for a
    /// local one the account it runs as, which matters more and is otherwise
    /// invisible.
    private func subtitle(for agent: AIProvider) -> String {
        if agent.isNotchCLI, let account = accounts.account(for: agent) {
            return account.summary
        }
        return agent.model ?? ""
    }

    /// Everything that doesn't need to be one click away.
    private var overflowMenu: some View {
        Menu {
            Button("Past chats") {
                withAnimation(.easeInOut(duration: 0.18)) { chat.showingHistory.toggle() }
            }
            Divider()
            Button("Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.markdown, forType: .string)
            }
            ForEach(ChatStore.ExportFormat.allCases, id: \.self) { format in
                Button("Export as \(format.menuTitle)…") {
                    if let url = chat.export(format) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Divider()
            Button("Settings…") {
                NotificationCenter.default.post(name: .visorOpenSettings, object: nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Design.Metric.iconSmall, weight: .medium))
                .foregroundStyle(Design.Ink.secondary)
                .frame(width: Design.Metric.small, height: Design.Metric.small)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Past chats, export, settings")
    }

    // MARK: - Empty transcript

    private var emptyState: some View {
        EmptyInvitation(chat: chat)
            .padding(.top, Design.Space.normal)
    }

    // MARK: - History

    private var history: some View {
        VStack(spacing: 0) {
            // Opening a chat got you back, but only if you wanted one. Without
            // this there was no way out of the list at all — the control that
            // opened it lives in an overflow menu that the list itself covers.
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { chat.showingHistory = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(Design.Surface.hover))
                    .contentShape(Capsule())
                }
                .buttonStyle(.visorBare)
                .keyboardShortcut(.escape, modifiers: [])

                Text("\(chat.store.summaries.count) saved")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            historyList
        }
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if chat.store.summaries.isEmpty {
                    Text("No saved chats yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.vertical, 14)
                }
                ForEach(chat.store.summaries) { row in
                    HistoryRow(
                        summary: row,
                        isCurrent: row.id == chat.conversation.id,
                        open: { chat.open(row.id) },
                        delete: { chat.delete(row.id) })
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

/// One turn. The user's turn is a right-aligned bubble; the agent's is plain
/// text on the card, which keeps long replies readable at this width.
struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    /// 1.0 in the notch; the HUD raises it so the transcript grows with the
    /// rails rather than staying notch-sized on a full screen.
    @Environment(\.hudScale) private var scale

    @ViewBuilder
    var body: some View {
        if message.role == .tool || message.role == .system {
            // Plumbing. What ran is shown on the assistant turn that asked.
            EmptyView()
        } else if message.role == .assistant,
                  let calls = message.toolCalls, !calls.isEmpty,
                  message.content.isEmpty {
            ToolActivityRow(calls: calls)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(Design.Typography.body(scale))
                    .foregroundStyle(Design.Ink.primary)
                    .lineSpacing(Design.Typography.bodyLeading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("visor.message.user")
                    .padding(.horizontal, Design.Space.roomy)
                    .padding(.vertical, Design.Space.normal)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: Design.Radius.panel, bottomLeadingRadius: Design.Radius.panel,
                            bottomTrailingRadius: 4, topTrailingRadius: Design.Radius.panel,
                            style: .continuous)
                            .fill(Design.Surface.raisedStrong))
            }
        } else {
            HStack {
                Group {
                    if isStreaming && message.content.isEmpty {
                        // Waiting on the first token: this *is* the message.
                        //
                        // The indicator alone, at 22pt, was a large abstract
                        // shape sitting where a sentence goes — it said
                        // something was happening without saying what. Sized to
                        // the text beside it, it reads as a line in the
                        // transcript rather than a graphic pasted over one.
                        HStack(spacing: Design.Space.snug) {
                            DotMatrixIndicator(size: 13 * scale, tint: Design.Retro.accent)
                            Text("Working")
                                .font(Design.Typography.body(scale))
                                .foregroundStyle(Design.Ink.tertiary)
                        }
                        .padding(.vertical, Design.Space.tight)
                    } else {
                        replyText
                    }
                }
                // The reply is the card's own voice: no bubble, full measure.
                // One surface level fewer, and a reading width that isn't
                // paying for a box.
                .padding(.horizontal, Design.Space.hair)
                .padding(.vertical, Design.Space.tight)
                Spacer(minLength: 0)
            }
        }
    }

    /// Real Markdown blocks, streamed on a throttle and settled once the
    /// reply completes — see `MessageBody`.
    private var replyText: some View {
        MessageBody(content: message.content, streaming: isStreaming, scale: scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("visor.message.assistant")
    }
}

private struct HistoryRow: View {
    let summary: ConversationSummary
    let isCurrent: Bool
    let open: () -> Void
    let delete: () -> Void

    @State private var hovering = false
    @State private var confirming = false

    /// Two buttons side by side, not a tap gesture with a button inside it.
    ///
    /// The row used to carry `.onTapGesture`, which claims the click before a
    /// nested Button ever sees it — so the trash icon looked interactive and
    /// did nothing. Opening and deleting are separate hit regions now.
    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 8) {
                    // A rail rather than a fill: it marks the current chat
                    // without turning the row into a block of colour.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isCurrent ? Design.Retro.accent : .clear)
                        .frame(width: 2, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title.isEmpty ? "Untitled" : summary.title)
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(isCurrent ? 0.95 : 0.82))
                            .lineLimit(1)
                        Text("\(summary.agentName) · \(summary.messageCount) messages")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.visor)

            // Two-step, because deleting a chat also erases what the knowledge
            // base learned from it — and a single mis-click shouldn't do that.
            if hovering || confirming {
                // Two steps, because deleting a chat also erases what the
                // knowledge base learned from it. The armed state says
                // "Delete?" rather than only turning red — a colour change
                // alone reads as a button that did nothing.
                Button {
                    if confirming { delete() } else { confirming = true }
                } label: {
                    Group {
                        if confirming {
                            Text("Delete?")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.red.opacity(0.95))
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(height: 22)
                    .padding(.horizontal, confirming ? 6 : 0)
                    .frame(minWidth: 22)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control)
                        .fill(confirming ? Color.red.opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.visorBare)
                .help(confirming ? "Click again to delete" : "Delete this chat")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Design.Radius.pill)
            .fill(hovering ? Design.Surface.hover : .clear))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { over in
            hovering = over
            // Leaving the row disarms it, so it can't sit primed and catch you.
            if !over { confirming = false }
        }
    }
}

struct ModeSwitcher: View {
    let mode: VisorMode
    let onSelect: (VisorMode) -> Void

    /// Three 24pt pills with 2pt between them. Fixed, because the note and chat
    /// cards each reserve exactly this much space for the switcher that the
    /// root draws over them.
    static let width: CGFloat = 76

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VisorMode.pickable) { candidate in
                Button { onSelect(candidate) } label: {
                    Image(systemName: candidate.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 16)
                        .foregroundStyle(candidate == mode
                                         ? Design.Ink.primary : Design.Ink.tertiary)
                }
                // The selected fill is the style's business now, so the
                // switcher's "on" state matches every other on state.
                .buttonStyle(.visor(active: candidate == mode))
                .accessibilityIdentifier("visor.mode.\(candidate.rawValue)")
                .help(candidate == .computerUse
                      ? "Computer Use — click to open"
                      : "\(candidate.title) — \(ShortcutSettings.hint(.swapMode)) swaps from anywhere")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: mode)
    }
}

/// Model chip for a local CLI agent.
///
/// There was a chip here before and it was dead text: the composer offered
/// OpenRouter's catalogue to hosted agents and, to a CLI agent, printed the
/// model name with nothing to click. Changing it meant Settings, which is not
/// where you are when you want a different model.
struct CLIModelPicker: View {
    @ObservedObject var chat: ChatController
    @State private var showing = false
    @State private var query = ""

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 4) {
                Text(chat.cliModelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.6)
            }
            .composerPill(active: true, enabled: true)
        }
        .buttonStyle(.visorBare)
        .help("Model for this agent — changing it starts a new chat")
        .popover(isPresented: $showing, arrowEdge: .top) { menu }
    }

    private var menu: some View {
        CLISelector(chat: chat, query: $query) { showing = false }
            .onDisappear { query = "" }
    }
}

/// One row: what you'd call it, what it's actually called, and whether you
/// want it near the top next time.
private struct CLIModelRow: View {
    let model: CLICatalogue.Model
    let selected: Bool
    let pinned: Bool
    let choose: () -> Void
    let pin: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .opacity(selected ? 1 : 0)
                .frame(width: 10)

            Button(action: choose) {
                HStack(spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                    if let note = model.note {
                        Text(note)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    Spacer(minLength: 8)
                    // The id, quietly. It's what the CLI is told, so it should
                    // be visible before you pick — but it isn't the thing
                    // you're choosing between.
                    Text(model.id)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(hovering ? 0.4 : 0.22))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.visor)

            // Its own button, outside the choosing one: pinning a model you
            // aren't switching to is the normal case, and a nested tap target
            // that also changes your model would be a trap.
            Button(action: pin) {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 9))
                    .foregroundStyle(pinned ? Color.yellow.opacity(0.8)
                                            : .white.opacity(hovering ? 0.35 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.visor)
            .help(pinned ? "Unpin" : "Pin to the top")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.control)
                .fill(hovering ? Design.Surface.hover : .clear)
                .padding(.horizontal, 6))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}


/// The composer's text view.
///
/// Two things AppKit will not do for a text view living in a nonactivating
/// panel, both of which it does automatically anywhere else.
///
/// The caret. The insertion point is drawn by a timer that AppKit starts when a
/// text view becomes first responder *in a key window*. The notch takes key
/// status after the click that focuses the field, so the order is inverted and
/// the timer never starts — the field accepts every keystroke and shows no sign
/// of being focused, which is a strange thing to be handed.
///
/// The cursor. Cursor rects are consulted only for the key window, so the
/// pointer stayed an arrow over a field you could type in — the one place the
/// cursor carries information, since the arrow is how you tell a label from
/// something you can type in before you commit to clicking.
final class ComposerTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { restartCaret() }
        return became
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        // Focus can arrive before key status. When key status follows, start
        // the caret then.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc private func windowBecameKey() {
        guard window?.firstResponder === self else { return }
        restartCaret()
    }

    private func restartCaret() {
        updateInsertionPointStateAndRestartTimer(true)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        // .activeAlways, because the panel is usually not the active app's key
        // window and .activeInKeyWindow would never fire.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

/// The message composer.
///
/// An NSTextView rather than SwiftUI's TextField: `TextField` on macOS gives
/// you no usable selection — you can't drag-select, and ⌘C on a partial
/// selection doesn't work — which is unacceptable for a field people paste
/// prompts into and edit. NSTextView is what the note rows already use, for
/// the same reason.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    /// Reports the laid-out height of the text so the field can grow.
    ///
    /// Counting newlines was wrong: a long line that *wraps* adds no newline,
    /// so the field stayed one line tall and everything past the first line
    /// was invisible. Only the layout manager knows how tall the text is.
    var onHeightChange: ((CGFloat) -> Void)?
    /// Point size of the typed text. Defaults to the notch card's 12; the HUD
    /// passes a larger value, since at full-screen the 12pt field read as a
    /// caption next to everything around it.
    var fontSize: CGFloat = 12
    /// Extra leading between lines, in points. ChatGPT sets 1.5 line height
    /// on its 16px type; the card and HUD pass their own.
    var lineSpacing: CGFloat = 0
    /// Reports first-responder changes, so the composer can light up.
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Assembled by hand rather than NSTextView.scrollableTextView(), which
        // gives no way to substitute a subclass — and the caret and the cursor
        // both need one. This is the same construction that convenience method
        // performs internally.
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none

        // Spelled with explicit CGFloats: NSSize's initialiser is overloaded
        // and the bare literals leave it ambiguous.
        let unbounded = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: 0, height: unbounded))
        container.widthTracksTextView = true
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)

        let view = ComposerTextView(frame: .zero, textContainer: container)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: unbounded, height: unbounded)
        scroll.documentView = view
        view.delegate = context.coordinator
        view.drawsBackground = false
        // Spelled out rather than relying on defaults: selection is the whole
        // reason this isn't a SwiftUI TextField.
        view.isEditable = true
        view.isSelectable = true
        view.font = .systemFont(ofSize: fontSize)
        if lineSpacing > 0 {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            view.defaultParagraphStyle = style
            view.typingAttributes = [.font: NSFont.systemFont(ofSize: fontSize),
                                     .paragraphStyle: style,
                                     .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
        }
        view.textColor = NSColor.white.withAlphaComponent(0.92)
        view.insertionPointColor = NSColor.white.withAlphaComponent(0.8)
        view.textContainerInset = NSSize(width: 0, height: 1)
        // NSTextContainer pads each line fragment by 5pt on the leading edge by
        // default, so the caret and the first character sat 5pt right of the
        // SwiftUI placeholder drawn behind them — putting the blinking caret
        // through the middle of the placeholder's first letter. Zero it so the
        // text view's origin and the placeholder's agree.
        view.textContainer?.lineFragmentPadding = 0
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.allowsUndo = true
        view.string = text

        // The panel is a non-activating panel that only becomes key when
        // something needs it, so ask for key status explicitly — otherwise the
        // text view can be first responder in a window that never took focus,
        // and selection and typing both go nowhere.
        DispatchQueue.main.async {
            view.window?.makeKeyAndOrderFront(nil)
            view.window?.makeFirstResponder(view)
            context.coordinator.reportHeight(of: view)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        // Only write back when the model genuinely diverges, or every keystroke
        // would reset the insertion point to the end.
        if view.string != text {
            view.string = text
            context.coordinator.reportHeight(of: view)
        }
        view.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ComposerField

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            reportHeight(of: view)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange?(false)
        }

        func reportHeight(of view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            parent.onHeightChange?(layout.usedRect(for: container).height)
        }

        /// Return sends; Shift-Return inserts a newline. Both arrive as
        /// insertNewline:, so the modifier on the live event is what separates
        /// them.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                view.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }
    }
}

/// The "something is happening" indicator: a 3x3 grid of dots that light in a
/// shifting order.
///
/// A spinner reads as *waiting* — a progress bar with no information. A grid
/// re-firing in a different order every beat reads as *working*, which is the
/// honest signal while tokens are arriving.
///
/// Driven by TimelineView rather than a Timer, so there's nothing to invalidate
/// when the view goes away and it stops on its own when off-screen. The order
/// is a deterministic shuffle of the nine cells seeded by the step, so it looks
/// random without needing a random source.
struct DotMatrixIndicator: View {
    var size: CGFloat = 12
    var tint: Color = .white
    /// Seconds per beat.
    var beat: Double = 0.16

    private let columns = 3
    /// Dot diameter as a fraction of the whole. Bigger dots at a small size
    /// read as blobs rather than a matrix.
    private let dotRatio: CGFloat = 7

    var body: some View {
        TimelineView(.periodic(from: .now, by: beat)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / beat)
            let ranks = Self.ranking(for: step)
            let dot = size / dotRatio

            VStack(spacing: dot / 2) {
                ForEach(0..<columns, id: \.self) { row in
                    HStack(spacing: dot / 2) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            Circle()
                                .fill(tint.opacity(Self.opacity(forRank: ranks[index])))
                                .frame(width: dot, height: dot)
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: beat * 0.9), value: step)
        }
        .accessibilityLabel("Working")
    }

    /// Rank 0 is brightest. Three lit, three mid, three dim — enough contrast
    /// to read movement at 12pt without the whole grid flashing.
    private static func opacity(forRank rank: Int) -> Double {
        switch rank {
        case 0..<3: return 0.9
        case 3..<6: return 0.45
        default:    return 0.15
        }
    }

    /// Fisher-Yates over the nine cells, seeded by the step: same step always
    /// gives the same pattern, consecutive steps look unrelated.
    private static func ranking(for step: Int) -> [Int] {
        var order = Array(0..<9)
        var seed = UInt64(bitPattern: Int64(step)) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        for i in stride(from: 8, through: 1, by: -1) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            order.swapAt(i, Int((seed >> 33) % UInt64(i + 1)))
        }
        // order[rank] = cell; invert so callers can ask a cell for its rank.
        var rank = [Int](repeating: 0, count: 9)
        for (r, cell) in order.enumerated() { rank[cell] = r }
        return rank
    }
}

/// Model chooser that lives in the composer, with search.
///
/// The model is a decision about the message you're writing, so it belongs
/// next to where you write it — and with several hundred models behind the
/// key, a plain menu is a scrolling column you can't navigate.
struct InlineModelPicker: View {
    @ObservedObject var chat: ChatController

    @State private var showing = false
    @State private var query = ""

    /// With no query, the agent's pinned models. With one, the whole
    /// catalogue. Several hundred entries is a list you search, not one you
    /// scroll — opening straight into it made choosing a model into hunting
    /// for one.
    private var showingPinned: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var matches: [String] {
        showingPinned ? chat.favouriteModels
                      : ModelSearch.filter(chat.modelOptions, query: query)
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 4) {
                Circle().fill(vendorColor(chat.conversation.model)).frame(width: 5, height: 5)
                Text(chat.shortModelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.6)
            }
            .composerPill(active: true, enabled: chat.agent != nil)
        }
        .buttonStyle(.visorBare)
        .disabled(chat.agent == nil)
        .help("Model for this message")
        .popover(isPresented: $showing, arrowEdge: .top) { picker }
    }

    // MARK: The picker (content lives in ModelSelector, so the lab can render it)

    private var picker: some View {
        ModelSelector(chat: chat, query: $query) { id in choose(id) }
    }

    private func choose(_ id: String) {
        chat.useModel(id)
        showing = false
        query = ""
    }

    /// Vendor · context · price for the second line.
    private func metaLine(_ id: String, _ model: ORModel?) -> String {
        var parts = [vendorDisplay(id)]
        if let ctx = contextLabel(model) { parts.append(ctx) }
        if let price = priceLabel(model) { parts.append(price) }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// Search results grouped by vendor, first-seen order kept — so the list
    /// reads as families, the way every good model picker groups them.
    private var groupedMatches: [ModelGroup] {
        var order: [String] = []
        var map: [String: [String]] = [:]
        for id in matches {
            let v = vendorDisplay(id)
            if map[v] == nil { order.append(v) }
            map[v, default: []].append(id)
        }
        return order.map { ModelGroup(vendor: $0, ids: map[$0]!) }
    }
}

/// A vendor's models, grouped for the picker. A struct, not a tuple, because
/// SwiftUI's ForEach needs `Identifiable` and Swift has no key path to a tuple
/// element.
private struct ModelGroup: Identifiable {
    let vendor: String
    let ids: [String]
    var id: String { vendor }
}

/// Full-screen HUD: the same conversation at another scale.
///
/// Built from the same pieces as the chat card, so the two stay in step as
/// either changes.
///
/// They no longer share matched-geometry ids. That worked while both faces
/// lived in one window; the HUD now has its own — which is what stopped the
/// menu bar flashing — and SwiftUI cannot interpolate geometry across two
/// windows. The transition is the HUD scaling out of the notch instead. The
/// ids were left in place for a while afterwards doing nothing, with comments
/// claiming a behaviour that no longer existed.
///
/// Everything emanates from the notch. Rails arrive at the screen edges, but
/// they start from behind the notch to get there: two motion origins would
/// fight, and one origin is what keeps this feeling like the notch opening up
/// rather than an unrelated window appearing.
struct HUDView: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var store: NotesStore
    var notchWidth: CGFloat
    var topInset: CGFloat
    var onExit: () -> Void
    /// Put Visor away entirely, remembering it was the HUD you closed. Distinct
    /// from `onExit`, which steps back down to the chat card.
    var onClose: () -> Void
    /// Drives the whole entrance and exit. One value, one animation — two
    /// curves competing over the same frames is what made it arrive in pieces.
    var visible: Bool
    /// Bumped after a deletion so the dictation panel re-reads the log.
    @State private var voiceRefresh: Int = 0
    @StateObject private var layout = HUDLayout()
    /// Persisted so the HUD reopens at the density you left it.
    @AppStorage("visor.hudOpacity") private var glass: Double = 0.8
    /// Reading text scales from this — body, secondary and caption roles in
    /// the conversation. Chrome and rails never do: layout adapts by rule.
    @AppStorage("visor.hudScale") private var scale: Double = 1.0

    /// Below this width the rails step aside and the conversation has the
    /// whole surface.
    private static let railsBreakpoint: CGFloat = 1180
    private static let leftRail: CGFloat = 236
    private static let rightRail: CGFloat = 260

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
                // The glass fades; only the content moves. A material being
                // scaled is rasterised mid-animation and re-rendered sharp
                // at the end, which reads as a tone shift. This way the blur
                // is only ever drawn at its final size.
                .opacity(visible ? 1 : 0)

            GeometryReader { geo in
                let wide = geo.size.width >= Self.railsBreakpoint
                HStack(alignment: .top, spacing: Design.Space.wide) {
                    if wide {
                        rail(layout.left, side: .left)
                            .frame(width: Self.leftRail)
                            // Offsets rather than conditionals, so the centre
                            // never shifts as the rails arrive.
                            .offset(x: visible ? 0 : -(Self.leftRail + 60))
                            .opacity(visible ? 1 : 0)
                    }

                    // Grows out of the notch: the screen's top centre.
                    centre
                        .frame(maxWidth: .infinity)
                        .scaleEffect(visible ? 1 : 0.04, anchor: .top)
                        .opacity(visible ? 1 : 0)

                    if wide {
                        rail(layout.right, side: .right)
                            .frame(width: Self.rightRail)
                            .offset(x: visible ? 0 : Self.rightRail + 60)
                            .opacity(visible ? 1 : 0)
                    }
                }
                .padding(.horizontal, Design.Space.section)
                .padding(.top, topInset + Design.Space.loose)
                .padding(.bottom, Design.Space.wide)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .environment(\.hudScale, scale)
        }
        // One curve for everything. Long and well damped, because it covers a
        // screen of travel and anything snappier reads as a snap.
        .animation(Design.Motion.animation(Design.Motion.hud), value: visible)
        .onExitCommand(perform: onExit)
    }

    // MARK: Backdrop

    /// The glass. A material thick enough to suppress the desktop's detail,
    /// tinted dark enough to read against; the slider fades the whole thing
    /// so it can range from overlay to opaque. Under Reduce Transparency it
    /// is a plain dark fill, and reads as an overlay by its edge alone.
    private var backdrop: some View {
        RoundedRectangle(cornerRadius: Design.Radius.surface, style: .continuous)
            .fill(Design.Motion.reducedTransparency
                  ? AnyShapeStyle(Design.Surface.glassOpaque)
                  : AnyShapeStyle(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.surface, style: .continuous)
                .fill(Design.Surface.glassTint))
            .opacity(Design.Motion.reducedTransparency ? 1 : glass)
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.surface, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06 + 0.08 * glass), lineWidth: Design.Stroke.hairline))
    }

    // MARK: Centre column

    /// The conversation is the surface. No box around the transcript: the
    /// glass is its background, and the reading measure is the constraint.
    private var centre: some View {
        VStack(spacing: Design.Space.roomy) {
            HStack(spacing: Design.Space.normal) {
                AgentIdentity(chat: chat)
                Text(chat.conversation.title.isEmpty ? "New conversation" : chat.conversation.title)
                    .font(Design.Typography.secondary())
                    .foregroundStyle(Design.Ink.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                IconButton(symbol: "arrow.down.right.and.arrow.up.left",
                           help: "Back to the notch — Esc, or \(ShortcutSettings.hint(.hud))",
                           action: onExit)
                    .accessibilityIdentifier("visor.hud.exit")
            }
            .frame(maxWidth: Design.Metric.readingWidth + Design.Space.section * 2)

            TranscriptView(chat: chat, layout: .hud, active: visible) {
                EmptyInvitation(chat: chat, scale: scale)
                    .padding(.top, Design.Space.section)
            }
            .frame(maxWidth: Design.Metric.readingWidth + Design.Space.section * 2)

            Composer(chat: chat, layout: .hud)
                .frame(maxWidth: Design.Metric.readingWidth)
                .padding(.bottom, Design.Space.tight)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Rails

    private func rail(_ panels: [HUDPanel], side: HUDLayout.Side) -> some View {
        VStack(spacing: Design.Space.roomy) {
            ForEach(Array(panels.enumerated()), id: \.offset) { index, panel in
                if panel != .none {
                    HUDPanelSlot(panel: panel,
                                 collapsed: layout.isCollapsed(panel),
                                 onPick: { layout.set($0, side: side, index: index) },
                                 onToggle: { layout.toggleCollapsed(panel) }) {
                        panelContent(panel)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Each panel is the real feature, not a view of it.
    @ViewBuilder
    private func panelContent(_ panel: HUDPanel) -> some View {
        switch panel {
        case .agents:    agentsPanel
        case .tasks:     HUDTasksPanel(store: store, chat: chat, scale: 1)
        case .chats:     HUDChatsPanel(chat: chat, scale: 1)
        case .memory:    memoryPanel
        case .dictation: dictationPanel
        case .none:      EmptyView()
        }
    }

    private var agentsPanel: some View {
        VStack(alignment: .leading, spacing: Design.Space.hair) {
            if chat.chatAgents.isEmpty {
                Text("No agents yet.")
                    .font(Design.Typography.secondary())
                    .foregroundStyle(Design.Ink.tertiary)
            }
            ForEach(Array(chat.chatAgents.enumerated()), id: \.element.id) { index, agent in
                let current = agent.name == chat.agent?.name
                Button { chat.use(agent) } label: {
                    HStack(spacing: Design.Space.normal) {
                        StatusDot(state: current && chat.isStreaming ? .working : (current ? .idle : .absent))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.name)
                                .font(current ? Design.Typography.secondaryMedium() : Design.Typography.secondary())
                                .foregroundStyle(Design.Ink.primary)
                                .lineLimit(1)
                            Text(agent.isNotchCLI ? agent.command : (agent.model ?? ChatController.defaultModel))
                                .font(Design.Typography.caption())
                                .foregroundStyle(Design.Ink.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if index < 5 {
                            Text(ShortcutSettings.agentHint(index))
                                .font(Design.Typography.mono(0.85))
                                .foregroundStyle(Design.Ink.faint)
                        }
                    }
                    .padding(.horizontal, Design.Space.normal)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.visor(active: current))
                .focusable(false)
            }
        }
    }

    @ViewBuilder
    private var memoryPanel: some View {
        if !chat.graph.isEnabled {
            Text("Off. Turn it on in Settings → Memory and Visor starts learning from your conversations.")
                .font(Design.Typography.caption())
                .foregroundStyle(Design.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let top = chat.graph.prominent(limit: 8)
            if top.isEmpty {
                Text("Nothing learned yet — it fills in as you talk.")
                    .font(Design.Typography.caption())
                    .foregroundStyle(Design.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Design.Space.snug) {
                    ForEach(top, id: \.node.id) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: Design.Space.snug) {
                            Text(entry.node.name)
                                .font(Design.Typography.secondary())
                                .foregroundStyle(Design.Ink.primary)
                                .lineLimit(1)
                            Text(entry.node.kind)
                                .font(Design.Typography.caption())
                                .foregroundStyle(Design.Ink.tertiary)
                            Spacer(minLength: 0)
                            Text("\(entry.degree)")
                                .font(Design.Typography.mono(0.85))
                                .foregroundStyle(Design.Ink.faint)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dictationPanel: some View {
        let recent = VoiceLog.recent(limit: 6)
        let _ = voiceRefresh   // re-reads when an entry is deleted
        if recent.isEmpty {
            Text("Nothing dictated yet.")
                .font(Design.Typography.secondary())
                .foregroundStyle(Design.Ink.tertiary)
        } else {
            VStack(alignment: .leading, spacing: Design.Space.snug) {
                ForEach(recent) { entry in
                    HUDVoiceRow(entry: entry, scale: 1) {
                        VoiceLog.delete(entry.id)
                        voiceRefresh &+= 1
                    }
                }
            }
        }
    }
}

/// Pixelated input-level meter, shown while dictating.
///
/// Deliberately blocky rather than a smooth waveform: at this size a
/// continuous curve is a wobbling line you can't read, where lit and unlit
/// cells are legible at a glance and match the dot-matrix indicator's
/// language.
/// The dot grid both voice states are drawn on.
///
/// One view, two things to say. Splitting it meant the meter and the
/// transcribing animation drifted apart in dot size and spacing, which is how
/// you end up with two visual languages for one feature.
///
/// Never animates layout: every dot is fixed and only opacity moves. An earlier
/// version resized bars on every sample, thirty-six times a second, and
/// SwiftUI re-laid-out the row each frame.
struct DotGrid: View {
    /// Outer: columns, left to right. Inner: rows, top to bottom. 0…1.
    var columns: [[Double]]
    var cell: CGFloat = 2
    /// Hot cells warm towards orange. White fire is just noise; the colour is
    /// most of what makes it read as flame rather than as static.
    var warm = false
    /// Fire changes on its own every frame, so animating each dot on top of
    /// that is a smear. Games move a few dots at a time and want the easing.
    var animated = true

    private var spacing: CGFloat { cell * 0.6 }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, rows in
                VStack(spacing: spacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, value in
                        Circle()
                            .fill(colour(for: value))
                            .opacity(0.06 + 0.9 * max(0, min(1, value)))
                            .frame(width: cell, height: cell)
                            .animation(animated ? .easeOut(duration: 0.09) : nil,
                                       value: value)
                    }
                }
            }
        }
    }

    private func colour(for value: Double) -> Color {
        guard warm else { return .white }
        // Cool at the tips, white-hot at the base — the way a flame actually
        // grades, and the way every fire effect of that era faked it.
        let heat = max(0, min(1, value))
        return Color(red: 1,
                     green: 0.45 + 0.55 * heat,
                     blue: 0.15 + 0.75 * heat * heat)
    }
}

/// One wave, drawn in dots, passing right to left behind the notch.
///
/// Each column is a moment: the newest sample enters at the right of the right
/// meter, travels left, disappears behind the notch, and comes out the left
/// meter still moving. Both sides read the same buffer, which is why they line
/// up — a peak travels across rather than happening twice.
///
/// Dots fade rather than switch. Rows split the scale evenly from the middle
/// outwards and each fades across its own share, so a rising voice sweeps the
/// dots instead of stepping between two states.
struct AudioLevelMeter: View {
    /// Oldest first. One per column.
    var samples: [Float]
    /// How old the first sample here is, in columns, counting back from the
    /// newest in the whole buffer. The right meter starts at 13, the left at 27.
    var oldestAge: Int
    var rows = 10
    var cell: CGFloat = 2

    var body: some View {
        DotGrid(columns: samples.enumerated().map { index, sample in
            // Sounds fade as they travel.
            //
            // Without this a single syllable stayed at full height for the
            // entire crossing — which is by definition however long the buffer
            // is, so one word occupied the whole meter for the best part of a
            // second and it felt like it would never leave. Now it enters
            // bright and trails off, which is also what an echo does.
            let age = Double(oldestAge - index)
            let faded = Float(Double(sample) * pow(0.87, age))
            return (0..<rows).map { opacity(sample: faded, row: $0) }
        }, cell: cell)
        .accessibilityLabel("Microphone level")
    }

    private func opacity(sample: Float, row: Int) -> Double {
        let value = Double(max(0, min(1, sample)))
        // Silence is silence, or the meter looks switched on before anyone has
        // spoken.
        guard value > 0.02 else { return 0 }

        let centre = Double(rows - 1) / 2
        let distance = abs(Double(row) - centre)
        let share = 1.0 / (centre + 1)
        let reach = (distance + 1) * share
        return max(0, min(1, (value - (reach - share)) / share))
    }
}

/// What the notch does while it's listening: invaders, shot down by talking.
///
/// The fire effect that briefly replaced this was a process rather than a
/// picture, which solved legibility by having nothing to read — and read as
/// noise for exactly the same reason. A game you can lose is worth more than
/// an effect you can only watch.
///
/// The formation spans the notch: both pills read one grid, so the row
/// continues behind the gap rather than two separate games being played either
/// side of it.
struct VoiceInvaders: View {
    @ObservedObject var arcade: VoiceArcade
    let side: ListeningPill.Side

    private static let perSide = 20

    var body: some View {
        let offset = side == .trailing ? Self.perSide : 0
        DotGrid(columns: (0..<Self.perSide).map { index in
            let column = index + offset
            return arcade.grid.indices.contains(column)
                ? arcade.grid[column]
                : Array(repeating: 0, count: VoiceArcade.rows)
        })
    }
}

/// Voice Pong, which is the invaders' sibling: a simulation your voice
/// changes, drawn across both pills as one board with the notch for a net.
struct VoicePongView: View {
    @ObservedObject var pong: VoicePong
    let side: ListeningPill.Side

    private static let perSide = 20

    var body: some View {
        let offset = side == .trailing ? Self.perSide : 0
        DotGrid(columns: (0..<Self.perSide).map { index in
            let column = index + offset
            return pong.grid.indices.contains(column)
                ? pong.grid[column]
                : Array(repeating: 0, count: VoicePong.rows)
        })
    }
}

/// What the notch does while it's thinking: Pong, with the notch as the net.
///
/// Three attempts got here. A spinner in each pill was one idea drawn twice. A
/// pulse sliding past was abstract — a thing moving is not a thing being done.
/// A marching sprite was better but needed a second and a third to read, and
/// transcription now finishes in about half of one, so nobody ever saw it.
///
/// That is the actual constraint: it has to be legible in a glance, because a
/// glance is all it gets. Pong solves it because the paddles are there the
/// instant it appears — two of them, either side of a gap — so it announces
/// itself before the ball has moved. And the notch was always going to be the
/// net; a game that is played across a divide, on a screen with a divide down
/// the middle of it.
///
/// Nothing is simulated. Position is a pair of triangle waves read from the
/// clock, so both halves agree without sharing state, and it survives being
/// interrupted at any moment because there is no moment it is part-way
/// through.
struct NotchPong: View {
    let side: ListeningPill.Side

    private static let total = 40
    private static let perSide = 20
    private static let rows = 10
    /// A full round trip. Fast, because the ball may only get one crossing.
    private static let rally: Double = 1.1
    /// Vertical period, deliberately not a multiple of the horizontal one so
    /// the ball doesn't retrace the same path every rally.
    private static let bounce: Double = 0.73
    private static let paddleHeight = 3

    var body: some View {
        TimelineView(.animation) { context in
            DotGrid(columns: columns(at: context.date))
        }
    }

    /// 0…span and back again, on `period`.
    private func triangle(_ t: Double, period: Double, span: Double) -> Double {
        let phase = t.truncatingRemainder(dividingBy: period) / period
        return (phase < 0.5 ? phase * 2 : (1 - phase) * 2) * span
    }

    private func columns(at date: Date) -> [[Double]] {
        let t = date.timeIntervalSinceReferenceDate
        // Inset by one so the ball turns at the paddles rather than at the wall.
        let ballX = triangle(t, period: Self.rally, span: Double(Self.total - 3)) + 1
        let ballY = triangle(t, period: Self.bounce, span: Double(Self.rows - 1))

        // Each paddle tracks the ball only as it comes towards it, and drifts
        // on a slow wave of its own the rest of the time.
        //
        // They used to share one number — both sat on the ball's row all the
        // time — so they rose and fell together, in step, like a single paddle
        // drawn twice. That reads as mechanism, not play. A paddle only needs
        // to be under the ball at the moment it arrives; the rest of the rally
        // is its own business. So how much each one follows the ball scales
        // with how near the ball is to its wall, squared: at contact it is
        // exactly there — nobody is playing, and a miss would need a score —
        // and mid-court it is off doing something else. Both are still read
        // off the clock, so the halves agree without sharing state.
        func paddleTop(nearWallAt wallX: Double, wander period: Double, phase: Double) -> Int {
            let travel = Double(Self.total - 3)
            let nearness = 1 - min(1, abs(ballX - wallX) / travel)
            let follow = nearness * nearness
            let idle = triangle(t + phase, period: period,
                                span: Double(Self.rows - Self.paddleHeight))
            let centre = ballY - Double(Self.paddleHeight) / 2
            let top = idle + (centre - idle) * follow
            return max(0, min(Self.rows - Self.paddleHeight, Int(top.rounded())))
        }
        let leadingTop = paddleTop(nearWallAt: 1, wander: 1.9, phase: 0.4)
        let trailingTop = paddleTop(nearWallAt: Double(Self.total - 2), wander: 2.7, phase: 1.3)
        let offset = side == .trailing ? Self.perSide : 0

        return (0..<Self.perSide).map { index in
            let column = index + offset
            return (0..<Self.rows).map { row in
                if column == 0 {
                    return (row >= leadingTop && row < leadingTop + Self.paddleHeight) ? 1 : 0
                }
                if column == Self.total - 1 {
                    return (row >= trailingTop && row < trailingTop + Self.paddleHeight) ? 1 : 0
                }
                // A little tolerance, so the ball reads as a ball crossing dots
                // rather than a dot switching on and off.
                let dx = abs(Double(column) - ballX)
                let dy = abs(Double(row) - ballY)
                guard dx < 1.2, dy < 1.2 else { return 0 }
                return max(0, 1 - (dx * dx + dy * dy) / 2)
            }
        }
    }
}

/// Microphone toggle plus the live level, on the trailing edge of the chat
/// header.
///
/// The meter only appears while recording — a permanently visible meter reading
/// zero is noise, and its arrival is the clearest signal that the mic is
/// actually open.
struct DictationControl: View {
    @ObservedObject var voice: VoiceInput
    var onToggle: () -> Void
    /// Button diameter. 20 in a header strip; the composer passes its row's
    /// button size so the mic matches the send circle beside it.
    var size: CGFloat = 20
    /// A bordered round button (the composer) rather than a bare icon.
    var circular = false

    var body: some View {
        HStack(spacing: 6) {
            if voice.state == .recording {
                AudioLevelMeter(samples: Array(voice.levels.suffix(14)), oldestAge: 13)
            } else if voice.state == .transcribing {
                // Matched to the level meter it replaces, so the control
                // doesn't shrink when recording stops and processing starts.
                DotMatrixIndicator(size: 16)
            }

            Button(action: onToggle) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: circular ? .medium : .regular))
                    .foregroundStyle(circular && voice.state == .idle ? Color.white.opacity(0.85) : tint)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(circular ? 0.06 : 0)))
                    .overlay(Circle().stroke(Color.white.opacity(circular ? 0.16 : 0), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(circular ? .visor(radius: size / 2) : .visor)
            .focusable(false)
            .help(helpText)
        }
    }

    private var symbol: String {
        switch voice.state {
        case .recording:    return "mic.fill"
        case .transcribing: return "waveform"
        case .denied:       return "mic.slash"
        default:            return "mic"
        }
    }

    private var tint: Color {
        switch voice.state {
        case .recording:         return Design.Retro.accent
        case .denied:            return .red.opacity(0.7)
        case .failed:            return .orange.opacity(0.8)
        default:                 return .white.opacity(0.45)
        }
    }

    private var helpText: String {
        switch voice.state {
        case .recording:    return "Stop and transcribe — \(ShortcutSettings.hint(.dictate))"
        case .transcribing: return "Transcribing…"
        case .denied:       return "Microphone access denied — enable it in System Settings > Privacy"
        case .failed(let why): return why
        case .idle:         return "Dictate — \(ShortcutSettings.hint(.dictate))"
        }
    }
}

/// The notch growing sideways while you dictate.
///
/// Painted the same black as the notch and squared off on its leading edge, so
/// it reads as the camera housing widening rather than a panel appearing next
/// to it. It shows only the level while recording and only the dot matrix while
/// transcribing — there's nothing else worth saying in 86 points, and anything
/// more would make it a UI rather than an indicator.
struct ListeningPill: View {
    /// Which side of the notch this one sits on. Everything mirrors: the
    /// rounded corner is on the outer edge, and the overlap reaches back under
    /// the strip from the inner one.
    enum Side { case leading, trailing }

    @ObservedObject var voice: VoiceInput
    @ObservedObject private var visuals = NotchVisuals.shared
    var height: CGFloat
    var side: Side = .trailing

    var body: some View {
        ZStack {
            // Square against the notch, rounded only on the outer bottom corner
            // to echo the notch's own. A rounded inner corner drew a visible
            // seam and made this read as a second notch beside the first,
            // rather than the one notch getting wider.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: side == .leading ? 10 : 0,
                bottomTrailingRadius: side == .trailing ? 10 : 0,
                topTrailingRadius: 0)
                .fill(Color.black)
                // Reach back under the notch strip so the black is continuous
                // even though the strip is a few points wider than the
                // hardware. Black over black — invisible, and no seam.
                .padding(side == .leading ? .trailing : .leading,
                         -NotchController.listeningPillOverlap)

            content
        }
        .frame(width: NotchController.listeningPillWidth, height: height)
    }

    @ViewBuilder
    private var content: some View {
        // Both sides are the same wave at different ages: the right meter holds
        // the newest samples, the left the ones that have already passed behind
        // the notch. Reading one buffer is what makes the halves line up, so a
        // peak appears to travel across rather than to happen twice.
        switch voice.state {
        case .recording:
            switch visuals.during {
            case .invaders:  VoiceInvaders(arcade: voice.arcade, side: side)
            case .voicePong: VoicePongView(pong: voice.pong, side: side)
            case .pong:      NotchPong(side: side)
            }
        case .transcribing:
            switch visuals.after {
            case .pong:  NotchPong(side: side)
            case .quiet: Color.clear
            }
        default:
            statusContent
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch voice.state {
        case .transcribing:
            // Sized to the pill rather than tucked inside it. This is the only
            // thing on screen while a transcript is being cleaned up, and at 13
            // it read as a detail in an empty space instead of the answer to
            // "is it still working".
            DotMatrixIndicator(size: 22)
        case .denied:
            Image(systemName: "mic.slash")
                .font(.system(size: 10))
                .foregroundStyle(.red.opacity(0.8))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        // Recording is drawn by the caller, which needs to know which side of
        // the notch it is on to pick its half of the wave.
        case .recording:
            EmptyView()
        }
    }
}


/// How large everything in the HUD is drawn. 1.0 in the notch card; the HUD
/// sets it from its own slider so the transcript scales with the rails.
private struct HUDScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var hudScale: Double {
        get { self[HUDScaleKey.self] }
        set { self[HUDScaleKey.self] = newValue }
    }
}


/// Matching for the model pickers.
///
/// Plain substring matching failed the obvious case: typing "glm 5.3" found
/// nothing because the id is "glm-5.3-flash" — the separators differ and the
/// name has a suffix. Both the query and the id are stripped to letters and
/// digits before comparing, and a multi-word query matches when every word
/// appears somewhere, so "flash glm" works too.
enum ModelSearch {
    static func filter(_ ids: [String], query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ids }

        let squashed = normalise(trimmed)
        let words = trimmed
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { normalise(String($0)) }
            .filter { !$0.isEmpty }

        return ids.filter { id in
            let target = normalise(id)
            // "glm53" against "glm53flash", or every word present in any order.
            if !squashed.isEmpty && target.contains(squashed) { return true }
            return !words.isEmpty && words.allSatisfy { target.contains($0) }
        }
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}


/// The composer's secondary controls — reasoning effort and fast routing —
/// folded behind one button, so the composer shows the model and the send and
/// nothing else until you go looking. The best composers keep the input clean;
/// three controls in a row was the opposite of that.
struct ComposerOptions: View {
    @ObservedObject var chat: ChatController
    @State private var showing = false

    var body: some View {
        // ChatGPT's plus: everything optional behind one round button. A
        // summary appears beside it only once something is set.
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(chat.agent == nil ? 0.25 : 0.85))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                if chat.isFast || chat.effort != nil {
                    Text(summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Design.Retro.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.visor(radius: 16))
        .focusable(false)
        .disabled(chat.agent == nil)
        .help("Reasoning effort and speed — \(summary)")
        .popover(isPresented: $showing, arrowEdge: .top) {
            OptionsSelector(chat: chat)
        }
    }

    private var summary: String {
        var bits: [String] = []
        if let e = chat.effort { bits.append(e == "medium" ? "med" : e) }
        if chat.isFast { bits.append("fast") }
        return bits.isEmpty ? "Options" : bits.joined(separator: " · ")
    }
}

/// How hard the model should think, per message.
///
/// Sent as OpenRouter's `reasoning.effort`. Models that don't reason ignore
/// it, so there's no need to hide the control per model — and hiding it would
/// mean maintaining a list of which models reason, which goes stale.
struct EffortPicker: View {
    @ObservedObject var chat: ChatController

    /// A segmented control, not a cycling button.
    ///
    /// Cycling hides the options and makes you click three times to go
    /// backwards. Four segments fit comfortably at this size and show the
    /// whole range at once, which is the point of having the control.
    ///
    /// Hidden entirely for models that don't reason — OpenRouter publishes
    /// `supported_parameters` per model, so that's read rather than guessed.
    var body: some View {
        if chat.supportsEffort {
            HStack(spacing: 3) {
                // A brain, matching the model picker's reasoning chip — the two
                // controls that decide how the model thinks now share a mark, so
                // the row reads as one instrument rather than three.
                Image(systemName: "brain")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(chat.agent == nil ? 0.22 : 0.45))
                    .padding(.leading, 6)
                HStack(spacing: 1) {
                    ForEach(ChatController.effortLevels, id: \.self) { level in
                        segment(level)
                    }
                }
                .padding(.trailing, 2)
            }
            // Height 18 to line up with the model and Fast pills, which the old
            // 20pt made half a point tall against.
            .padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.055)))
            .fixedSize()
            .disabled(chat.agent == nil)
            .help("How hard this model thinks before answering")
        }
    }

    private func segment(_ level: String?) -> some View {
        let selected = level == chat.effort
        return Button {
            chat.useEffort(level)
        } label: {
            Text(label(for: level))
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(selected ? 0.9 : 0.38))
                .padding(.horizontal, 6)
                .frame(height: 14)
                .background(Capsule().fill(.white.opacity(selected ? 0.14 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.visorBare)
        .animation(.easeOut(duration: 0.14), value: selected)
    }

    private func label(for level: String?) -> String {
        switch level {
        case "low":    return "low"
        case "medium": return "med"
        case "high":   return "high"
        default:       return "auto"
        }
    }
}

/// Route to the fastest provider rather than the cheapest.
///
/// OpenRouter serves most models from several providers and optimises for
/// price by default. This asks for throughput instead — it costs more per
/// token, which is worth it for short interactive turns and not for long ones.
struct FastToggle: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        Button(action: chat.toggleFast) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(chat.isFast ? Design.Retro.accent : Color.white.opacity(0.5))
                // Labelled, not a bare icon. A lightning bolt on its own does
                // not say "route to the fastest provider rather than the
                // cheapest one" to anybody.
                Text(chat.isFast ? "Fast" : "Standard")
            }
            // Inside the label. Applied to the Button instead, the background
            // it draws was never part of the button's hit area — which is why
            // only the text responded and the chevron did nothing.
            .composerPill(active: chat.isFast, enabled: chat.agent != nil)
        }
        .buttonStyle(.visorBare)
        .fixedSize()
        .disabled(chat.agent == nil)
        .help(chat.isFast
              ? "Routing to the quickest provider serving this model. Costs more per token."
              : "Routing to the cheapest provider serving this model.")
    }
}


/// What the agent did, rather than the raw tool exchange.
///
/// The call and its result are both in the transcript because the model needs
/// them next turn, but neither is something a person wants to read — so the
/// turn that asked for tools renders as a line naming them.
struct ToolActivityRow: View {
    let calls: [ToolCall]

    var body: some View {
        HStack(spacing: Design.Space.snug) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: Design.Metric.iconSmall))
                .foregroundStyle(Design.Ink.tertiary)
            Text(calls.map(\.name).joined(separator: ", "))
                .font(Design.Typography.mono())
                .foregroundStyle(Design.Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.roomy)
        .frame(height: Design.Metric.regular)
        .raised(Design.Radius.control)
    }
}


extension InlineModelPicker {
    func vendor(of id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/")[0]) + " /" : ""
    }

    func shortName(of id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").dropFirst().joined(separator: "/")) : id
    }

    /// A vendor's display name, since raw ids capitalise badly ("openai" →
    /// "Openai"). Falls back to a plain capitalisation for vendors not listed.
    func vendorDisplay(_ id: String) -> String {
        let v = (id.split(separator: "/").first.map { $0.lowercased() }) ?? ""
        switch v {
        case "anthropic":            return "Anthropic"
        case "openai":               return "OpenAI"
        case "google":               return "Google"
        case "meta-llama", "meta":   return "Meta"
        case "mistralai", "mistral": return "Mistral"
        case "deepseek":             return "DeepSeek"
        case "x-ai":                 return "xAI"
        case "qwen", "alibaba":      return "Qwen"
        case "cohere":               return "Cohere"
        case "perplexity":           return "Perplexity"
        case "":                     return ""
        default:                     return v.prefix(1).uppercased() + v.dropFirst()
        }
    }

    /// A colour per vendor, so the list groups itself at a glance without the
    /// name having to spell out who made the model.
    func vendorColor(_ id: String) -> Color {
        let vendor = (id.split(separator: "/").first.map { $0.lowercased() }) ?? ""
        switch vendor {
        case "anthropic":            return Color(red: 0.83, green: 0.52, blue: 0.30)
        case "openai":               return Color(red: 0.20, green: 0.72, blue: 0.55)
        case "google":               return Color(red: 0.36, green: 0.60, blue: 0.96)
        case "meta-llama", "meta":   return Color(red: 0.30, green: 0.50, blue: 0.95)
        case "mistralai", "mistral": return Color(red: 0.95, green: 0.50, blue: 0.25)
        case "deepseek":             return Color(red: 0.52, green: 0.44, blue: 0.92)
        case "x-ai":                 return Color(white: 0.78)
        case "qwen", "alibaba":      return Color(red: 0.64, green: 0.42, blue: 0.86)
        case "cohere":               return Color(red: 0.86, green: 0.44, blue: 0.66)
        default:                     return Color.white.opacity(0.35)
        }
    }

    /// Small capability marks: reasoning, vision, tools — only the ones the
    /// model actually has, read from what OpenRouter reports.
    @ViewBuilder
    func capabilityChips(_ model: ORModel?) -> some View {
        HStack(spacing: 3) {
            if model?.supportsReasoning ?? false { chip("brain") }
            if model?.supportsVision ?? false { chip("eye") }
            if model?.supportsTools ?? false { chip("wrench.and.screwdriver") }
        }
    }

    func chip(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8))
            .foregroundStyle(.secondary.opacity(0.7))
    }

    /// Context window, shortened: 200000 → "200K", 1000000 → "1M".
    func contextLabel(_ model: ORModel?) -> String? {
        guard let c = model?.context_length, c > 0 else { return nil }
        if c >= 1_000_000 { return "\(c / 1_000_000)M" }
        if c >= 1_000 { return "\(c / 1_000)K" }
        return "\(c)"
    }

    /// Prompt / completion price per million tokens, e.g. "$3/$15".
    func priceLabel(_ model: ORModel?) -> String? {
        guard let p = model?.promptPerMillion, let c = model?.completionPerMillion else { return nil }
        func f(_ v: Double) -> String {
            v == 0 ? "0" : (v < 1 ? String(format: "%.2f", v) : String(format: "%.0f", v))
        }
        return "$\(f(p))/\(f(c))"
    }

    func star(_ id: String) -> some View {
        Button { chat.toggleFavourite(id) } label: {
            Image(systemName: chat.isFavourite(id) ? "star.fill" : "star")
                .font(.system(size: 9))
                .foregroundStyle(chat.isFavourite(id) ? Design.Retro.accent : Color.secondary.opacity(0.45))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.visor)
        .help(chat.isFavourite(id) ? "Unpin from this agent" : "Pin to this agent")
    }
}


/// The composer's controls all wear this: same height, same corner, same
/// hover. Three controls that each invented their own padding is most of what
/// made the row look assembled rather than designed.
struct ComposerPill: ViewModifier {
    var active: Bool = false
    var enabled: Bool = true

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? (active ? Design.Ink.primary : Design.Ink.secondary) : Design.Ink.faint)
            .padding(.horizontal, Design.Space.roomy)
            .frame(height: Design.Metric.large)
            .background(
                Capsule().fill(.white.opacity(
                    !enabled ? 0.02 : hovering ? 0.12 : 0.05)))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(enabled ? Design.Stroke.control : Design.Stroke.divider,
                                            lineWidth: Design.Stroke.hairline))
            // Keyboard focus never lands on a chip: the ring AppKit draws for
            // it is a rounded rectangle that shows as ticks past a capsule's
            // ends. Return and ⌘↩ are the composer's keys; the chips are
            // for the pointer.
            .focusable(false)
            .contentShape(Capsule())
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

extension View {
    func composerPill(active: Bool = false, enabled: Bool = true) -> some View {
        modifier(ComposerPill(active: active, enabled: enabled))
    }
}

/// Asks before a tool does something that can't be taken back.
///
/// Shows the exact arguments, not just the tool's name: "run_shell" tells you
/// nothing, and approving a command you can't see is not consent. "Always"
/// is per-agent and per-tool, so trusting one agent with the shell doesn't
/// trust every agent with it.
struct ToolApprovalRow: View {
    let pending: ChatController.PendingApproval
    let allow: () -> Void
    let allowAlways: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.normal) {
            HStack(spacing: Design.Space.snug) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: Design.Metric.iconSmall, weight: .medium))
                    .foregroundStyle(Design.Retro.accent)
                Text(pending.needing.count == 1
                     ? "Let \(pending.needing[0].name) run?"
                     : "Let \(pending.needing.count) tools run?")
                    .font(Design.Typography.heading())
                    .foregroundStyle(Design.Ink.primary)
            }

            ForEach(pending.needing) { call in
                Text(summary(of: call))
                    .font(Design.Typography.mono())
                    .foregroundStyle(Design.Ink.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Design.Space.normal).padding(.vertical, Design.Space.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .fill(Color.black.opacity(0.4)))
            }

            HStack(spacing: Design.Space.snug) {
                ActionChip(title: "Allow", prominent: true, action: allow)
                    .spotlight("allow")
                    .accessibilityIdentifier("visor.approval.allow")
                ActionChip(title: "Always allow", action: allowAlways)
                    .accessibilityIdentifier("visor.approval.always")
                ActionChip(title: "Deny", action: deny)
                    .accessibilityIdentifier("visor.approval.deny")
                Spacer(minLength: 0)
            }
        }
        .padding(Design.Space.roomy)
        .raised(Design.Radius.panel, strong: true, stroke: Design.Retro.accent.opacity(0.45))
    }

    /// The arguments as written, so what's being approved is visible.
    private func summary(of call: ToolCall) -> String {
        let arguments = call.decodedArguments
        if let command = arguments["command"] as? String { return command }
        guard !arguments.isEmpty else { return call.name }
        return arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }
}

/// Hosts the listening extension without involving the card.
///
/// Always present in the view tree, drawing nothing when idle. That's the
/// point: the previous version was a conditional in StickyRootView, so
/// starting dictation changed state the *root* observed, which re-evaluated
/// the whole body and rebuilt the card underneath — the entire interface
/// blinking to reveal a 66pt extension beside the notch.
///
/// Observing the recorder here instead keeps every redraw inside this view.
struct ListeningPillHost: View {
    @ObservedObject var voice: VoiceInput
    var notch: CGSize
    /// Suppressed in the HUD, which has its own indicators and no notch strip.
    var suppressed: Bool

    @ObservedObject private var visuals = NotchVisuals.shared
    private var showing: Bool { voice.state.isBusy && !suppressed }

    var body: some View {
        ZStack(alignment: .top) {
            if showing {
                // The piece under the notch itself, for the game that grows
                // downward. Without it the two pills got taller and the
                // hardware notch between them didn't, which left a hole under
                // the camera and read as two pillars rather than one shape.
                // This is the bit that makes the three read as one section.
                if visuals.extraHeight > 0 {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: notch.width + NotchController.listeningPillOverlap * 2,
                               height: visuals.extraHeight + 1)
                        .offset(y: notch.height - 1)
                        .transition(.opacity)
                }
                // Taller for the game that needs it; the pill hangs from the
                // notch, so extra height goes downwards.
                ListeningPill(voice: voice, height: notch.height + visuals.extraHeight)
                    .offset(x: (notch.width + NotchController.listeningPillWidth) / 2
                               - NotchController.listeningPillOverlap / 2)
                    // Scales from its own leading edge rather than moving from
                    // the container's: the container spans the window, so
                    // `.move(edge: .leading)` flew it in from the far left of
                    // the screen.
                    .transition(.scale(scale: 0.01, anchor: .leading)
                        .combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showing)
        .allowsHitTesting(false)
    }
}


private struct HUDVoiceRow: View {
    let entry: VoiceEntry
    let scale: Double
    let delete: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        // A log is something you pull a line out of, not one you tidy — so a
        // click copies the transcript, and deleting is the deliberate act
        // tucked behind the hover. The trailing slot is a fixed width whether
        // or not its controls are showing, so the text never reflows when the
        // pointer arrives — the old version rebuilt the row and nudged every
        // line sideways on hover.
        HStack(alignment: .top, spacing: 6) {
            Text(entry.text)
                .font(.system(size: 11 * scale))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
            Spacer(minLength: 0)
            ZStack(alignment: .topTrailing) {
                if copied {
                    Text("Copied")
                        .font(.system(size: 8 * scale, weight: .semibold))
                        .foregroundStyle(.green.opacity(0.9))
                        .frame(height: 18 * scale)
                        .transition(.opacity)
                } else {
                    Button(action: delete) {
                        Image(systemName: "trash")
                            .font(.system(size: 9 * scale))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 18 * scale, height: 18 * scale)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.visor)
                    .help("Delete this entry")
                    .opacity(hovering ? 1 : 0)
                }
            }
            .frame(width: 40 * scale, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .onHover { hovering = $0 }
        .help("Click to copy")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeIn(duration: 0.2)) { copied = false }
        }
    }
}
