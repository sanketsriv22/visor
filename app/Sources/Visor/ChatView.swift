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
            HStack(spacing: 4) {
                ModeSwitcher(mode: mode, onSelect: onMode)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .frame(width: NotchController.shoulderWidth, alignment: .leading)
            Spacer(minLength: 0)
                .frame(width: notchWidth + NotchController.notchClearance)
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                if chat.isStreaming {
                    Button(action: chat.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop the reply — this also stops it being billed")
                }
                headerButton("square.and.pencil", "New chat") { chat.newChat() }
                headerButton("clock.arrow.circlepath", "Past chats") {
                    withAnimation(.easeInOut(duration: 0.18)) { chat.showingHistory.toggle() }
                }
                exportMenu.frame(width: 22)
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
            Text("·").foregroundStyle(.white.opacity(0.25)).font(.system(size: 9))
            modelPicker
            Spacer(minLength: 0)
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
                .frame(width: 22, height: 22)
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

    /// Change the running model without a trip to Settings — the agent's
    /// stored default updates with it.
    private var modelPicker: some View {
        Menu {
            ForEach(chat.modelOptions, id: \.self) { id in
                Button(id) { chat.useModel(id) }
            }
        } label: {
            Text(chat.shortModelName)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(chat.agent == nil)
        .help("Model this agent runs")
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
                                   agentName: chat.agent?.name ?? "Agent",
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
                Text("Replies stream here. ⌘⇧M switches back to your notes.")
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
                    ArticulatingSquare(size: 9)
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
private struct MessageRow: View {
    let message: ChatMessage
    let agentName: String
    let isStreaming: Bool

    @ViewBuilder
    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(.system(size: 12))
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(agentName.uppercased())
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.4))
                        if isStreaming { ArticulatingSquare(size: 7) }
                    }
                    replyText
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
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
        } else {
            Text(Self.rendered(message.content))
                .font(.system(size: 12))
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
            ForEach(VisorMode.allCases) { candidate in
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
                .help("\(candidate.title) — ⌘⇧M swaps from anywhere")
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
private struct ComposerField: NSViewRepresentable {
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

/// The "something is happening" indicator: a small square that rotates and
/// softens its corners in a continuous loop.
///
/// A spinner reads as *waiting* — a progress bar with no information. This
/// reads as *working*, which is the honest signal while tokens are arriving.
/// It's driven by a single repeating animation rather than a timer, so it
/// costs nothing and stops cleanly when the view goes away.
struct ArticulatingSquare: View {
    var size: CGFloat = 10
    var tint: Color = .white

    @State private var articulating = false

    var body: some View {
        RoundedRectangle(
            cornerRadius: articulating ? size * 0.46 : size * 0.17,
            style: .continuous)
            .fill(tint.opacity(articulating ? 0.85 : 0.5))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(articulating ? 180 : 0))
            .scaleEffect(articulating ? 0.78 : 1)
            .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true),
                       value: articulating)
            .onAppear { articulating = true }
            .accessibilityLabel("Working")
    }
}

/// Model chooser that lives in the composer, with search.
///
/// The model is a decision about the message you're writing, so it belongs
/// next to where you write it — and with several hundred models behind the
/// key, a plain menu is a scrolling column you can't navigate.
private struct InlineModelPicker: View {
    @ObservedObject var chat: ChatController

    @State private var showing = false
    @State private var query = ""

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ids = chat.modelOptions
        guard !q.isEmpty else { return ids }
        return ids.filter { $0.lowercased().contains(q) }
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
