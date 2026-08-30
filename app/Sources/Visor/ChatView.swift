import AppKit
import SwiftUI

/// The chat face of the notch: a transcript and a composer, in the same black
/// card the note uses so switching modes reads as one surface changing shape
/// rather than two different windows.
struct ChatCard: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var ai: AIRunner
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
    @State private var draftHeight: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            notchBand
            agentBar
            Divider().overlay(Color.white.opacity(0.08))
            if chat.showingHistory {
                history
            } else {
                transcript
                composer
            }
        }
        // Chrome and size belong to StickyRootView, so the card morphs between
        // modes as one shape instead of cross-fading with the note card.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand(perform: onClose)
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
                ModeSwitcher(mode: mode, onSelect: onMode)
                    .fixedSize()
            }
            .frame(width: NotchController.shoulderWidth, alignment: .trailing)
            Spacer(minLength: 0)
                .frame(width: notchWidth + NotchController.notchClearance)
            // 20pt slots with no spacing: five of these have to fit the same
            // 106pt shoulder the note card uses.
            HStack(spacing: 0) {
                if chat.isStreaming {
                    Button(action: chat.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop the reply — this also stops it being billed")
                }
                // Two buttons and an overflow. Five icon-only controls in a
                // 106pt strip is a puzzle, not a toolbar — new chat and expand
                // are the ones worth a permanent slot.
                headerButton("square.and.pencil", "New chat") { chat.newChat() }
                headerButton("arrow.up.left.and.arrow.down.right", "Expand to HUD — ⌘⇧M",
                             action: onHUD)
                overflowMenu.frame(width: 20)
                Spacer(minLength: 0)
            }
            .frame(width: NotchController.shoulderWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(height: topInset)
    }

    /// Who you're talking to and on what. Below the notch, where there's width
    /// for it — the band itself has to stay narrow to match the note card.
    private var agentBar: some View {
        HStack(spacing: 8) {
            agentPicker
            Spacer(minLength: 0)
            DictationControl(voice: chat.voice, onToggle: chat.toggleDictation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func headerButton(_ symbol: String, _ help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Agents are named by the user, so the picker shows names and keeps the
    /// model id as the subtitle — the name is what they think in.
    private var agentPicker: some View {
        Menu {
            ForEach(chat.chatAgents) { agent in
                Button {
                    chat.use(agent)
                } label: {
                    Text(agent.name)
                    if let model = agent.model { Text(model) }
                }
            }
            if chat.chatAgents.isEmpty {
                Text("No agents yet")
            }
            Divider()
            Button("Manage agents…") {
                NotificationCenter.default.post(name: .visorOpenSettings, object: nil)
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(chat.isStreaming ? Color.orange : Color.white.opacity(0.35))
                    .frame(width: 5, height: 5)
                Text(chat.agent?.name ?? "No agent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Past chats, export, settings")
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.conversation.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chat.conversation.messages) { message in
                        MessageRow(message: message,
                                   isStreaming: chat.isStreaming && message.id == chat.conversation.messages.last?.id)
                            .id(message.id)
                    }
                    if let pending = chat.pendingApproval {
                        ToolApprovalRow(pending: pending,
                                        allow: { chat.approvePending(always: false) },
                                        allowAlways: { chat.approvePending(always: true) },
                                        deny: chat.denyPending)
                            .id("approval")
                    }
                    if let error = chat.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                            .id("error")
                    }
                    // Anchor to scroll to; scrolling to the last message would
                    // stop short of the composer while text is still growing.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: chat.conversation.messages.last?.content) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.conversation.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chat.chatAgents.isEmpty ? "No agents yet" : "Ask \(chat.agent?.name ?? "your agent") anything")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            if chat.chatAgents.isEmpty {
                HStack(spacing: 4) {
                    Text("Add one with an API key in")
                    Button("Settings") {
                        NotificationCenter.default.post(name: .visorOpenSettings, object: nil)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .underline()
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            } else {
                Text("Replies stream here. ⌘⇧I switches back to your notes.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text("Message \(chat.agent?.name ?? "your agent")…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                        .allowsHitTesting(false)
                }
                ComposerField(text: $chat.draft, onSubmit: chat.send) { height in
                    // Clamped here rather than in the field: the field
                    // measures, the composer decides how much room to give.
                    let clamped = min(max(height, 16), Self.composerMaxHeight)
                    if abs(clamped - draftHeight) > 0.5 { draftHeight = clamped }
                }
            }
            .frame(height: draftHeight)
            .animation(.easeOut(duration: 0.12), value: draftHeight)

            // The model belongs here, not two rows up: it's a decision you
            // make about the message you're writing.
            HStack(spacing: 6) {
                InlineModelPicker(chat: chat)
                EffortPicker(chat: chat)
                FastToggle(chat: chat)

                if chat.isStreaming {
                    DotMatrixIndicator(size: 11)
                    Text("working")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 0)

                Text(chat.isStreaming ? "⌘." : "↩")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.22))

                Button(action: chat.isStreaming ? chat.stop : chat.send) {
                    Image(systemName: chat.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(chat.isStreaming
                                         ? Color.orange
                                         : (canSend ? Color.white.opacity(0.9) : Color.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
                .disabled(!chat.isStreaming && !canSend)
                .keyboardShortcut(chat.isStreaming ? "." : .return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.09), lineWidth: 1)))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// Three lines, then it scrolls. Enough to see what you're writing
    /// without the composer eating the transcript it belongs to.
    static let composerMaxHeight: CGFloat = 48

    private var canSend: Bool {
        !chat.isStreaming
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - History

    private var history: some View {
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
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 11, bottomLeadingRadius: 11,
                            bottomTrailingRadius: 3, topTrailingRadius: 11)
                            .fill(.white.opacity(0.11)))
            }
        } else {
            HStack {
                Group {
                    if isStreaming && message.content.isEmpty {
                        // Waiting on the first token: the indicator *is* the
                        // message. No name, no empty bubble text — just the
                        // thing that says work is happening, at a size you can
                        // read without leaning in.
                        DotMatrixIndicator(size: 30 * scale)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                    } else {
                        replyText
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                // Dimmer and squared off on the leading edge, so the two
                // speakers read as different without shouting.
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 11, bottomLeadingRadius: 3,
                        bottomTrailingRadius: 11, topTrailingRadius: 11)
                        .fill(.white.opacity(0.045)))
                Spacer(minLength: 28)
            }
        }
    }

    /// Markdown is parsed only once the reply is complete. Re-parsing an
    /// attributed string on every streamed token is the difference between a
    /// smooth stream and a stuttering one.
    @ViewBuilder
    private var replyText: some View {
        if isStreaming {
            Text(message.content)
                .font(.system(size: 12 * scale))
                .foregroundStyle(.white.opacity(0.88))
        } else {
            Text(Self.rendered(message.content))
                .font(.system(size: 12 * scale))
                .foregroundStyle(.white.opacity(0.88))
                .textSelection(.enabled)
        }
    }

    private static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

private struct HistoryRow: View {
    let summary: ConversationSummary
    let isCurrent: Bool
    let open: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title.isEmpty ? "Untitled" : summary.title)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isCurrent ? 0.95 : 0.8))
                    .lineLimit(1)
                Text("\(summary.agentName) · \(summary.messageCount) messages")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovering {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Delete this chat, and forget it")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(hovering ? Color.white.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}

/// Switches the notch between its two faces.
///
/// It sits where the VISOR wordmark used to, in the notch's left shoulder —
/// the one spot that reads identically in both modes, so the control doesn't
/// appear to jump when you use it. ⌘1 / ⌘2 do the same thing.
struct ModeSwitcher: View {
    let mode: VisorMode
    let onSelect: (VisorMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VisorMode.switchable) { candidate in
                Button { onSelect(candidate) } label: {
                    Image(systemName: candidate.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(candidate == mode ? Color.white.opacity(0.15) : .clear))
                        .foregroundStyle(.white.opacity(candidate == mode ? 0.9 : 0.36))
                }
                .buttonStyle(.plain)
                .help("\(candidate.title) — ⌘⇧I swaps from anywhere")
                .keyboardShortcut(candidate == .notes ? "1" : "2", modifiers: .command)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: mode)
    }
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none

        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.drawsBackground = false
        // Spelled out rather than relying on defaults: selection is the whole
        // reason this isn't a SwiftUI TextField.
        view.isEditable = true
        view.isSelectable = true
        view.font = .systemFont(ofSize: 12)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: beat)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / beat)
            let ranks = Self.ranking(for: step)
            let dot = size / 5

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
                Text(chat.shortModelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .opacity(0.6)
            }
            .composerPill(active: true, enabled: chat.agent != nil)
        }
        .buttonStyle(.plain)
        .disabled(chat.agent == nil)
        .help("Model for this message")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(spacing: 0) {
                TextField("Search \(chat.modelOptions.count) models…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(7)
                Divider()
                if showingPinned {
                    HStack {
                        Text("PINNED")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.6)
                        Spacer()
                        Text("type to search all")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text(showingPinned
                                 ? "Nothing pinned yet. Search, then tap a star to pin it here."
                                 : "Nothing matches “\(query)”")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(9)
                        }
                        ForEach(matches, id: \.self) { id in
                            row(id)
                        }
                    }
                }
                // The overlay scroller sat on top of the star and grew when
                // grabbed, covering it entirely. Hidden, with the list inset
                // from the edge so nothing needs to share that column.
                .scrollIndicators(.hidden)
                .frame(height: showingPinned ? 150 : 220)
            }
            .frame(width: 340)
        }
    }

    private func row(_ id: String) -> some View {
        let selected = id == chat.conversation.model
        return HStack(spacing: 4) {
            Button {
                chat.useModel(id)
                showing = false
                query = ""
            } label: {
                HStack(spacing: 6) {
                    // Vendor dimmed, model name normal: the prefix repeats down
                    // dozens of rows and shouldn't compete with what differs.
                    Text(vendor(of: id)).foregroundStyle(.secondary)
                    Text(shortName(of: id))
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                chat.toggleFavourite(id)
            } label: {
                Image(systemName: chat.isFavourite(id) ? "star.fill" : "star")
                    .font(.system(size: 9))
                    .foregroundStyle(chat.isFavourite(id) ? Color.orange : Color.secondary.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(chat.isFavourite(id) ? "Unpin from this agent" : "Pin to this agent")
        }
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? Color.accentColor.opacity(0.16) : .clear))
    }
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

    @State private var railsIn = false
    /// Persisted so the HUD reopens at the density you left it.
    @AppStorage("visor.hudOpacity") private var glass: Double = 0.8
    /// Everything in the HUD scales from this, so it can be read from across
    /// the room or packed in tight.
    @AppStorage("visor.hudScale") private var scale: Double = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            // The glass. Dark enough to read against, sheer enough that the
            // desktop underneath still reads as "overlay", not "app".
            // The slider fades the *material* as well as the tint. Previously
            // only the black overlay moved, so the blur stayed at full strength
            // and the HUD could never be more than translucent no matter how
            // far the slider went.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.55)))
                .opacity(glass)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.06 + 0.1 * glass), lineWidth: 1))

            HStack(alignment: .top, spacing: 18) {
                // Two panels a side rather than one: the HUD is screen-sized
                // and a single rail per edge left most of it empty.
                VStack(spacing: 14) {
                    rail(title: "Agents") { agentsRail }
                    rail(title: "What I know") { memoryRail }
                }
                .frame(width: 220 * scale)
                .offset(x: railsIn ? 0 : -140)
                .opacity(railsIn ? 1 : 0)

                centre

                VStack(spacing: 14) {
                    rail(title: "Open tasks") { tasksRail }
                    rail(title: "Recently said") { voiceRail }
                }
                .frame(width: 240 * scale)
                .offset(x: railsIn ? 0 : 140)
                .opacity(railsIn ? 1 : 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, topInset + 16)
            .padding(.bottom, 20)
            .environment(\.hudScale, scale)
        }
        .onAppear {
            // Rails follow the card rather than racing it, so the eye reads one
            // motion opening into three.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.12)) {
                railsIn = true
            }
        }
        .onExitCommand(perform: onExit)
    }

    // MARK: Centre column

    private var centre: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(chat.conversation.title.isEmpty ? "New conversation" : chat.conversation.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if chat.isStreaming { DotMatrixIndicator(size: 11) }
                Spacer(minLength: 0)

                // The notch extension is suppressed at this scale, so without
                // this the HUD gave no sign the microphone was open at all.
                DictationControl(voice: chat.voice, onToggle: chat.toggleDictation)

                // Transparency belongs in the HUD, not buried in Settings —
                // the right value depends on what's behind it right now.
                HStack(spacing: 5) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                    // Down to zero: fully clear is a legitimate setting for an
                    // overlay you want to see through completely.
                    Slider(value: $glass, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 80)
                }
                .help("How opaque the HUD is — all the way down is fully clear")

                HStack(spacing: 5) {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                    Slider(value: $scale, in: 0.85...1.8)
                        .controlSize(.mini)
                        .frame(width: 80)
                }
                .help("How big everything in the HUD is")

                Button(action: onExit) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to the notch — Esc, or ⌘⇧M")
            }

            HUDTranscript(chat: chat)

            HUDComposer(chat: chat)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Rails

    private func rail<Content: View>(title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9 * scale, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.35))
            content()
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(0.07), lineWidth: 1))
    }

    private var agentsRail: some View {
        VStack(alignment: .leading, spacing: 3) {
            if chat.chatAgents.isEmpty {
                Text("No agents yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
            ForEach(Array(chat.chatAgents.enumerated()), id: \.element.id) { index, agent in
                Button { chat.use(agent) } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agent.name == chat.agent?.name
                                  ? Color.orange : Color.white.opacity(0.25))
                            .frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.name)
                                .font(.system(size: 12 * scale))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                            Text(agent.model ?? ChatController.defaultModel)
                                .font(.system(size: 9 * scale))
                                .foregroundStyle(.white.opacity(0.3))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if index < 5 {
                            Text("⌘⇧\(index + 1)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.22))
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(agent.name == chat.agent?.name
                              ? Color.white.opacity(0.07) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func symbol(for status: TaskStatus) -> String {
        switch status {
        case .open:    return "circle"
        case .doing:   return "circle.lefthalf.filled"
        case .blocked: return "exclamationmark.circle"
        case .done:    return "checkmark.circle.fill"
        }
    }

    private func tint(for status: TaskStatus) -> Color {
        switch status {
        case .open:    return .white.opacity(0.35)
        case .doing:   return .orange
        case .blocked: return .red.opacity(0.8)
        case .done:    return .green.opacity(0.8)
        }
    }

    /// What the graph has learned, densest first.
    ///
    /// Entities with their claim counts rather than a node-and-edge drawing:
    /// a force-directed graph at this size is a hairball, and the useful
    /// question is "what does it know about" not "how is it shaped".
    @ViewBuilder
    private var memoryRail: some View {
        if !chat.graph.isEnabled {
            Text("Off. Turn it on in Settings → Memory and Visor starts learning from your conversations.")
                .font(.system(size: 10 * scale))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let top = chat.graph.prominent(limit: 7)
            if top.isEmpty {
                Text("Nothing learned yet — it fills in as you talk.")
                    .font(.system(size: 10 * scale))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(top, id: \.node.id) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.node.name)
                                .font(.system(size: 12 * scale))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                            Text(entry.node.kind)
                                .font(.system(size: 8 * scale))
                                .foregroundStyle(.white.opacity(0.3))
                            Spacer(minLength: 0)
                            Text("\(entry.degree)")
                                .font(.system(size: 9 * scale, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
            }
        }
    }

    /// The last few things dictated, whether or not they reached a chat.
    @ViewBuilder
    private var voiceRail: some View {
        let recent = VoiceLog.recent(limit: 5)
        if recent.isEmpty {
            Text("Nothing dictated yet.")
                .font(.system(size: 10 * scale))
                .foregroundStyle(.white.opacity(0.35))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(recent) { entry in
                    Text(entry.text)
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
        }
    }

    private var tasksRail: some View {
        VStack(alignment: .leading, spacing: 3) {
            let open = store.items.filter { $0.isTask && !$0.done }
            if open.isEmpty {
                Text("Nothing open")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
            ForEach(open.prefix(12)) { item in
                // Same gestures as the note itself: tap cycles
                // open -> doing -> blocked, long-press completes. Anything
                // else would make this a read-only copy of the tasks rather
                // than the tasks.
                HStack(alignment: .top, spacing: 8) {
                    Button { store.cycle(item.id) } label: {
                        Image(systemName: symbol(for: item.status))
                            .font(.system(size: 13 * scale))
                            .foregroundStyle(tint(for: item.status))
                            // The glyph is 13pt; the hit area is 24. A target
                            // the size of its icon is a target you miss.
                            .frame(width: 24 * scale, height: 24 * scale)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text(item.text)
                        .font(.system(size: 13 * scale))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .padding(.top, 4 * scale)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.35) { store.toggleDone(item.id) }
            }
        }
    }
}

/// The transcript, sized for the HUD.
private struct HUDTranscript: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.conversation.messages) { message in
                        MessageRow(message: message,
                                   isStreaming: chat.isStreaming
                                       && message.id == chat.conversation.messages.last?.id)
                    }
                    if let pending = chat.pendingApproval {
                        ToolApprovalRow(pending: pending,
                                        allow: { chat.approvePending(always: false) },
                                        allowAlways: { chat.approvePending(always: true) },
                                        deny: chat.denyPending)
                    }
                    if let error = chat.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.conversation.messages.last?.content) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

/// The composer, wider and taller than in the notch but the same control.
private struct HUDComposer: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text("Message \(chat.agent?.name ?? "your agent")…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                        .allowsHitTesting(false)
                }
                ComposerField(text: $chat.draft, onSubmit: chat.send)
            }
            .frame(height: 62)

            HStack(spacing: 8) {
                InlineModelPicker(chat: chat)
                EffortPicker(chat: chat)
                FastToggle(chat: chat)
                if chat.isStreaming {
                    DotMatrixIndicator(size: 11)
                    Text("working").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
                Button(action: chat.isStreaming ? chat.stop : chat.send) {
                    Image(systemName: chat.isStreaming
                          ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(chat.isStreaming ? Color.orange : Color.white.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(0.09), lineWidth: 1))
    }
}

/// Pixelated input-level meter, shown while dictating.
///
/// Deliberately blocky rather than a smooth waveform: at this size a
/// continuous curve is a wobbling line you can't read, where lit and unlit
/// cells are legible at a glance and match the dot-matrix indicator's
/// language.
struct AudioLevelMeter: View {
    var level: Float          // 0…1
    var columns = 5
    var rows = 4
    var cell: CGFloat = 2.5

    var body: some View {
        HStack(spacing: cell / 2) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: cell / 2) {
                    ForEach(0..<rows, id: \.self) { row in
                        // Rows fill from the bottom up.
                        let threshold = Float(rows - row) / Float(rows)
                        RoundedRectangle(cornerRadius: cell / 4)
                            .fill(Color.white.opacity(lit(column: column, threshold: threshold)))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityLabel("Microphone level")
    }

    /// Outer columns respond a little less than the centre, which reads as a
    /// meter rather than five identical bars moving in lockstep.
    private func lit(column: Int, threshold: Float) -> Double {
        let centre = Float(columns - 1) / 2
        let falloff = 1 - abs(Float(column) - centre) / (centre + 1) * 0.45
        return level * falloff >= threshold ? 0.85 : 0.12
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

    var body: some View {
        HStack(spacing: 6) {
            if voice.state == .recording {
                AudioLevelMeter(level: voice.level)
            } else if voice.state == .transcribing {
                DotMatrixIndicator(size: 10)
            }

            Button(action: onToggle) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        case .recording:         return .orange
        case .denied:            return .red.opacity(0.7)
        case .failed:            return .orange.opacity(0.8)
        default:                 return .white.opacity(0.45)
        }
    }

    private var helpText: String {
        switch voice.state {
        case .recording:    return "Stop and transcribe — ⌘⇧V"
        case .transcribing: return "Transcribing…"
        case .denied:       return "Microphone access denied — enable it in System Settings > Privacy"
        case .failed(let why): return why
        case .idle:         return "Dictate — ⌘⇧V"
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
    @ObservedObject var voice: VoiceInput
    var height: CGFloat

    var body: some View {
        ZStack {
            // Square on the leading edge so it butts flush against the notch,
            // rounded only on the trailing bottom corner to echo the notch's
            // own. A rounded leading corner drew a visible seam and made this
            // read as a second notch sitting beside the first, rather than the
            // one notch getting wider.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 10,
                topTrailingRadius: 0)
                .fill(Color.black)
                // Reach back under the notch strip so the black is continuous
                // even though the strip is a few points wider than the
                // hardware. Black over black — invisible, and no seam.
                .padding(.leading, -NotchController.listeningPillOverlap)

            content
        }
        .frame(width: NotchController.listeningPillWidth, height: height)
    }

    @ViewBuilder
    private var content: some View {
        switch voice.state {
        case .transcribing:
            DotMatrixIndicator(size: 13)
        case .recording:
            AudioLevelMeter(level: voice.level, columns: 9, rows: 4, cell: 2.5)
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
            HStack(spacing: 1) {
                ForEach(ChatController.effortLevels, id: \.self) { level in
                    segment(level)
                }
            }
            .padding(2)
            .background(Capsule().fill(.white.opacity(0.05)))
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
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
                    .foregroundStyle(chat.isFast ? Color.orange : Color.white.opacity(0.5))
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
        .buttonStyle(.plain)
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
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
            Text(calls.map(\.name).joined(separator: ", "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.04)))
    }
}


extension InlineModelPicker {
    func vendor(of id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/")[0]) + " /" : ""
    }

    func shortName(of id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").dropFirst().joined(separator: "/")) : id
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
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(enabled ? (active ? 0.9 : 0.5) : 0.22))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                Capsule().fill(.white.opacity(
                    !enabled ? 0.03 : active ? 0.14 : (hovering ? 0.10 : 0.055))))
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(pending.needing.count == 1
                     ? "Let \(pending.needing[0].name) run?"
                     : "Let \(pending.needing.count) tools run?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            ForEach(pending.needing) { call in
                Text(summary(of: call))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35)))
            }

            HStack(spacing: 6) {
                Button("Allow", action: allow)
                    .buttonStyle(.plain)
                    .composerPill(active: true)
                Button("Always", action: allowAlways)
                    .buttonStyle(.plain)
                    .composerPill()
                Button("Deny", action: deny)
                    .buttonStyle(.plain)
                    .composerPill()
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.orange.opacity(0.28), lineWidth: 1))
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

    private var showing: Bool { voice.state.isBusy && !suppressed }

    var body: some View {
        ZStack(alignment: .top) {
            if showing {
                ListeningPill(voice: voice, height: notch.height)
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
