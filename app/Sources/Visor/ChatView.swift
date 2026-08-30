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
    var namespace: Namespace.ID
    var onMode: (VisorMode) -> Void
    var onHUD: () -> Void
    var onClose: () -> Void

    @FocusState private var composerFocused: Bool
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
                    .matchedGeometryEffect(id: "transcript", in: namespace)
                composer
                    .matchedGeometryEffect(id: "composer", in: namespace)
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
            HStack(spacing: 4) {
                ModeSwitcher(mode: mode, onSelect: onMode)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .frame(width: NotchController.shoulderWidth, alignment: .leading)
            Spacer(minLength: 0)
                .frame(width: notchWidth + NotchController.notchClearance)
            // 20pt slots with no spacing: five of these have to fit the same
            // 106pt shoulder the note card uses.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
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
                headerButton("square.and.pencil", "New chat") { chat.newChat() }
                headerButton("clock.arrow.circlepath", "Past chats") {
                    withAnimation(.easeInOut(duration: 0.18)) { chat.showingHistory.toggle() }
                }
                exportMenu.frame(width: 20)
                headerButton("arrow.up.left.and.arrow.down.right", "Expand to HUD — ⌘⇧M",
                             action: onHUD)
            }
            .frame(width: NotchController.shoulderWidth, alignment: .trailing)
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

    private var exportMenu: some View {
        Menu {
            Button("Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.markdown, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            }
            Divider()
            ForEach(ChatStore.ExportFormat.allCases, id: \.self) { format in
                Button("Export as \(format.menuTitle)…") {
                    // Reveal it: an exported file the user can't find hasn't
                    // really been exported.
                    if let url = chat.export(format) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(copied ? 0.9 : 0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(chat.conversation.messages.isEmpty)
        .help("Copy or export this chat")
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
                    // Clamp here rather than in the field: the field just
                    // measures, the composer decides how much room it's
                    // willing to give.
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
    /// was invisible. Only the layout manager knows how tall the text
    /// actually is.
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
            let height = layout.usedRect(for: container).height
            parent.onHeightChange?(height)
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
    /// catalogue — several hundred entries is a list you search, not one you
    /// scroll.
    private var showingFavourites: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var matches: [String] {
        showingFavourites
            ? chat.favouriteModels
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

                if showingFavourites {
                    HStack {
                        Text("PINNED")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("type to search all")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text(showingFavourites
                                 ? "No pinned models yet. Search, then tap the star to pin one."
                                 : "Nothing matches “\(query)”")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                        }
                        ForEach(matches, id: \.self) { id in
                            row(id)
                        }
                    }
                }
                .frame(height: showingFavourites ? 150 : 220)
            }
            .frame(width: 340)
        }
    }

    private func row(_ id: String) -> some View {
        let selected = id == chat.conversation.model
        return HStack(spacing: 6) {
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
                    .foregroundStyle(chat.isFavourite(id) ? Color.orange : Color.secondary.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(chat.isFavourite(id) ? "Unpin" : "Pin to this agent")
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? Color.accentColor.opacity(0.16) : .clear))
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
