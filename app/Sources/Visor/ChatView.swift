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
                ComposerField(text: $chat.draft, onSubmit: chat.send)
            }
            .frame(height: composerHeight)

            // The model belongs here, not two rows up: it's a decision you
            // make about the message you're writing.
            HStack(spacing: 6) {
                InlineModelPicker(chat: chat)

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

    /// Grow with the draft, up to a ceiling — past that the field scrolls
    /// rather than eating the transcript.
    private var composerHeight: CGFloat {
        let lines = chat.draft.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return min(max(CGFloat(lines) * 15 + 3, 18), 90)
    }

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
        if message.role == .user {
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
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        // Only write back when the model genuinely diverges, or every keystroke
        // would reset the insertion point to the end.
        if view.string != text { view.string = text }
        view.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ComposerField

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
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

    private var matches: [String] {
        ModelSearch.filter(chat.modelOptions, query: query)
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 3) {
                Text(chat.shortModelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(chat.agent == nil)
        .help("Model for this message")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(spacing: 0) {
                TextField("Search models…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(7)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text("Nothing matches “\(query)”")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(9)
                        }
                        ForEach(matches, id: \.self) { id in
                            Button {
                                chat.useModel(id)
                                showing = false
                                query = ""
                            } label: {
                                HStack {
                                    Text(id).font(.system(size: 11)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if id == chat.conversation.model {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 220)
            }
            .frame(width: 340)
        }
    }
}

/// Full-screen HUD: the same conversation at another scale.
///
/// Deliberately built from the *same* pieces as the chat card rather than as a
/// separate screen — the transcript and composer carry matched-geometry ids, so
/// SwiftUI interpolates their frames and they physically travel into this
/// layout instead of cross-fading into a different one.
///
/// Everything emanates from the notch. Rails arrive at the screen edges, but
/// they start from behind the notch to get there: two motion origins would
/// fight, and one origin is what keeps this feeling like the notch opening up
/// rather than an unrelated window appearing.
struct HUDView: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var store: NotesStore
    var namespace: Namespace.ID
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
                rail(title: "Agents") { agentsRail }
                    .frame(width: 210 * scale)
                    .offset(x: railsIn ? 0 : -140)
                    .opacity(railsIn ? 1 : 0)

                centre

                rail(title: "Open tasks") { tasksRail }
                    .frame(width: 230 * scale)
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
                .matchedGeometryEffect(id: "transcript", in: namespace)

            HUDComposer(chat: chat)
                .matchedGeometryEffect(id: "composer", in: namespace)
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
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 11,
                bottomTrailingRadius: 11,
                topTrailingRadius: 0)
                .fill(Color.black)

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
