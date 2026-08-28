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
    var mode: VisorMode
    var onMode: (VisorMode) -> Void
    var onClose: () -> Void

    @FocusState private var composerFocused: Bool
    @State private var copied = false

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 18,
            topTrailingRadius: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)   // the strip behind the notch
            header
            Divider().overlay(Color.white.opacity(0.08))
            if chat.showingHistory {
                history
            } else {
                transcript
                composer
            }
        }
        .frame(width: NotchController.chatCardWidth,
               height: NotchController.chatCardHeight + topInset)
        .background(
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2))
        .overlay(CardEdgeBorder(radius: 18).stroke(.white.opacity(0.14), lineWidth: 1))
        .onExitCommand(perform: onClose)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // Same slot as on the note card, so the control doesn't move when
            // you use it.
            ModeSwitcher(mode: mode, onSelect: onMode)

            agentPicker

            Spacer(minLength: 4)

            if chat.isStreaming {
                Button(action: chat.stop) {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Stop the reply (and stop paying for it)")
            }

            headerButton("square.and.pencil", "New chat") { chat.newChat() }
            headerButton("clock.arrow.circlepath", "History") {
                withAnimation(.easeInOut(duration: 0.18)) { chat.showingHistory.toggle() }
            }
            exportMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func headerButton(_ symbol: String, _ help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
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
                Text("No chat agents yet")
            }
            Divider()
            Button("Manage agents…") { NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil) }
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
            Text(chat.chatAgents.isEmpty ? "No chat agents yet" : "Ask \(chat.agent?.name ?? "your agent") anything")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Text(chat.chatAgents.isEmpty
                 ? "Add one in Settings with your OpenRouter key, and pick which model it runs."
                 : "Replies stream here. ⌘1 switches back to your notes.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1...5)
                .focused($composerFocused)
                .onSubmit(chat.send)

            Button(action: chat.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(canSend ? Color.white.opacity(0.9) : Color.white.opacity(0.22))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
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
        .onAppear { composerFocused = true }
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
                    .background(RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.10)))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(agentName.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.32))
                body
            }
        }
    }

    /// Markdown is parsed only once the reply is complete. Re-parsing an
    /// attributed string on every streamed token is the difference between a
    /// smooth stream and a stuttering one.
    @ViewBuilder
    private var body: some View {
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
                .help("\(candidate.title) (⌘\(candidate == .notes ? "1" : "2"))")
                .keyboardShortcut(candidate == .notes ? "1" : "2", modifiers: .command)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: mode)
    }
}
