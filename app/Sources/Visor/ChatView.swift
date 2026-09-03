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
    @State private var draftHeight: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            notchBand
            agentBar
            Divider().overlay(Design.Surface.hairline)
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
                    .buttonStyle(.visor)
                    .help("Stop the reply — this also stops it being billed")
                }
                // Two buttons and an overflow. Five icon-only controls in a
                // 106pt strip is a puzzle, not a toolbar — new chat and expand
                // are the ones worth a permanent slot.
                headerButton("square.and.pencil", "New chat") { chat.newChat() }
                headerButton("arrow.up.left.and.arrow.down.right",
                             "Expand to HUD — \(ShortcutSettings.hint(.hud))",
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
                .foregroundStyle(Design.Ink.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        // Was .plain, which acknowledges a click with nothing at all. Every
        // icon button in the band now lifts on hover and gives on press.
        .buttonStyle(.visor)
        .help(help)
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

    /// Agents are named by the user, so the picker shows names and keeps the
    /// model id as the subtitle — the name is what they think in.
    private var agentPicker: some View {
        Menu {
            ForEach(chat.chatAgents) { agent in
                Button {
                    chat.use(agent)
                } label: {
                    Text(agent.name)
                    // For a local agent this says whose subscription answers.
                    // It was knowable only by asking the agent, which is not a
                    // thing anyone thinks to do about their own billing.
                    Text(subtitle(for: agent))
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Design.Surface.raised))
                .contentShape(Circle())
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
                    .buttonStyle(.visorBare)
                    .foregroundStyle(Color.accentColor)
                    .underline()
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            } else {
                Text("Replies stream here. \(ShortcutSettings.hint(.swapMode)) switches back to your notes.")
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
                // Only for hosted agents: a local CLI agent picks its model
                // through its own arguments, so offering OpenRouter's
                // catalogue here was a control that silently did nothing.
                if chat.agent?.isChat ?? false {
                    InlineModelPicker(chat: chat)
                    EffortPicker(chat: chat)
                    FastToggle(chat: chat)
                } else if chat.isCLIAgent {
                    CLIModelPicker(chat: chat)
                }

                // No "working" here and no keyboard hint. The transcript
                // already shows the agent thinking, where the reply will
                // appear; saying it twice is noise, and the ↩ / ⌘. glyph read
                // as a second button rather than a hint.
                Spacer(minLength: 0)

                Button(action: chat.isStreaming ? chat.stop : chat.send) {
                    Image(systemName: chat.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(chat.isStreaming
                                         ? Color.orange
                                         : (canSend ? Color.white.opacity(0.9) : Color.white.opacity(0.22)))
                }
                .buttonStyle(.visorBare)
                .disabled(!chat.isStreaming && !canSend)
                .keyboardShortcut(chat.isStreaming ? "." : .return, modifiers: [.command])
            }
            // Fixed, because a hosted agent shows three controls here and a CLI
            // agent shows one label — without this the whole composer changed
            // height as you switched between them.
            .frame(height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.panel)
                .fill(Design.Surface.hover)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.panel)
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
                        // Waiting on the first token: this *is* the message.
                        //
                        // The indicator alone, at 22pt, was a large abstract
                        // shape sitting where a sentence goes — it said
                        // something was happening without saying what. Sized to
                        // the text beside it, it reads as a line in the
                        // transcript rather than a graphic pasted over one.
                        HStack(spacing: 6) {
                            DotMatrixIndicator(size: 12 * scale)
                            Text("working")
                                .font(.system(size: 12 * scale))
                                .foregroundStyle(.white.opacity(0.5))
                        }
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
                        // 0.045 was all but invisible on black; this
                        // reads as a surface without competing with the
                        // user's own bubble.
                        .fill(.white.opacity(0.085)))
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 11, bottomLeadingRadius: 3,
                        bottomTrailingRadius: 11, topTrailingRadius: 11)
                        .stroke(Design.Surface.hairline, lineWidth: 1))
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
                        .fill(isCurrent ? Color.orange : .clear)
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

    /// Two 24pt pills with 2pt between them. Fixed, because the note and chat
    /// cards each reserve exactly this much space for the switcher that the
    /// root draws over them.
    static let width: CGFloat = 50

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VisorMode.switchable) { candidate in
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
                .help("\(candidate.title) — \(ShortcutSettings.hint(.swapMode)) swaps from anywhere")
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
                    .font(.system(size: 6, weight: .bold))
                    .opacity(0.6)
            }
            .composerPill(active: true, enabled: true)
        }
        .buttonStyle(.visorBare)
        .help("Model for this agent — changing it starts a new chat")
        .popover(isPresented: $showing, arrowEdge: .top) { menu }
    }

    private var menu: some View {
        VStack(spacing: 0) {
            search
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 286)
        .onDisappear { query = "" }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // Plain rather than .roundedBorder: a bordered box inside a
            // popover that already has an edge is two frames around one field.
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(useTyped)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var groups: [CLICatalogue.Group] {
        chat.cliGroups(matching: query)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    Text(group.id)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 3)
                    ForEach(group.models) { model in
                        CLIModelRow(model: model,
                                    selected: model.id == chat.cliModelID,
                                    pinned: chat.isFavourite(model.id),
                                    choose: {
                                        chat.useCLIModel(model.id)
                                        showing = false
                                    },
                                    pin: { chat.toggleFavourite(model.id) })
                    }
                }
                // Any name the CLI knows is valid, and this list is a snapshot
                // of one version of it. Typing something unlisted has to stay
                // possible or the picker becomes a smaller CLI.
                // An agent whose command we have no list for — a Codex or
                // whatever comes next. The picker still works: pin what you
                // use and type the rest. Better an honest empty list than a
                // confident one full of another tool's model names.
                if groups.isEmpty && query.isEmpty {
                    Text("No suggestions for this agent yet — type a model name it accepts, then pin it.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                if noMatches {
                    Button(action: useTyped) {
                        HStack(spacing: 6) {
                            Image(systemName: "return").font(.system(size: 9))
                            Text("Use “\(query.trimmingCharacters(in: .whitespaces))”")
                                .font(.system(size: 12))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.visor)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: 268)
    }

    private var footer: some View {
        Text("Starts a new chat — the CLI fixes its model when a session begins.")
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    /// Nothing in the list matches, but there is something typed — every CLI
    /// knows names this snapshot doesn't, so that has to stay usable.
    private var noMatches: Bool {
        groups.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func useTyped() {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        chat.useCLIModel(name)
        showing = false
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
                    .font(.system(size: 6, weight: .bold))
                    .opacity(0.6)
            }
            .composerPill(active: true, enabled: chat.agent != nil)
        }
        .buttonStyle(.visorBare)
        .disabled(chat.agent == nil)
        .help("Model for this message")
        .popover(isPresented: $showing, arrowEdge: .top) { picker }
    }

    // MARK: The picker

    private var picker: some View {
        VStack(spacing: 0) {
            // A borderless search with an icon, like a command palette rather
            // than a form field. Return picks the top result.
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search \(chat.modelOptions.count) models…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit { if let first = matches.first { choose(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    if matches.isEmpty {
                        Text(showingPinned
                             ? "Nothing pinned yet — search, then tap a star to keep a model here."
                             : "No model matches “\(query)”.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    } else if showingPinned {
                        Section {
                            ForEach(chat.favouriteModels, id: \.self) { modelRow($0) }
                        } header: {
                            sectionHeader("Pinned", trailing: "type to search all")
                        }
                    } else {
                        ForEach(groupedMatches) { group in
                            Section {
                                ForEach(group.ids, id: \.self) { modelRow($0) }
                            } header: {
                                sectionHeader(group.vendor)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .frame(height: showingPinned ? 240 : 340)
        }
        .frame(width: 396)
    }

    /// One model, two lines: the name, and a meta line of vendor · context ·
    /// price with capability marks — the facts you actually choose on.
    private func modelRow(_ id: String) -> some View {
        let selected = id == chat.conversation.model
        let model = chat.catalog.model(for: id)
        return HStack(spacing: 4) {
            Button { choose(id) } label: {
                HStack(spacing: 10) {
                    Circle().fill(vendorColor(id)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortName(of: id))
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(metaLine(id, model))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            capabilityChips(model)
                        }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(selected ? 1 : 0)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            star(id)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
    }

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
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
    /// Drives the whole entrance and exit. One value, one animation — the
    /// previous version ran a `.transition` on the HUD *and* a separate delayed
    /// offset on the rails, so two curves competed over the same frames, which
    /// is what made it feel laggy and arrive in pieces.
    var visible: Bool
    /// Bumped after a deletion so the dictation panel re-reads the log.
    @State private var voiceRefresh: Int = 0
    @StateObject private var layout = HUDLayout()
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
            RoundedRectangle(cornerRadius: Design.Radius.surface, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.surface, style: .continuous)
                    .fill(Color.black.opacity(0.55)))
                .opacity(glass)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.surface, style: .continuous)
                    .stroke(.white.opacity(0.06 + 0.1 * glass), lineWidth: 1))
                // The glass fades; only the content scales. A material that is
                // being scaled gets rasterised at whatever size the animation
                // passes through and re-rendered sharply once it settles, which
                // reads as the panel shifting tone abruptly at the end. This
                // way the blur is only ever drawn at its final size.
                .opacity(visible ? 1 : 0)

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 14) {
                    ForEach(Array(layout.left.enumerated()), id: \.offset) { index, panel in
                        HUDPanelSlot(panel: panel, scale: scale) {
                            layout.set($0, side: .left, index: index)
                        } content: {
                            panelContent(panel)
                        }
                    }
                }
                .frame(width: 230 * scale)
                // Offsets rather than conditionals, so the centre never shifts
                // as the rails arrive.
                .offset(x: visible ? 0 : -(230 * scale + 60))
                .opacity(visible ? 1 : 0)

                // Grows out of the notch: the screen's top centre, which is
                // what .top anchors to.
                centre
                    .scaleEffect(visible ? 1 : 0.04, anchor: .top)
                    .opacity(visible ? 1 : 0)

                VStack(spacing: 14) {
                    ForEach(Array(layout.right.enumerated()), id: \.offset) { index, panel in
                        HUDPanelSlot(panel: panel, scale: scale) {
                            layout.set($0, side: .right, index: index)
                        } content: {
                            panelContent(panel)
                        }
                    }
                }
                .frame(width: 250 * scale)
                .offset(x: visible ? 0 : 250 * scale + 60)
                .opacity(visible ? 1 : 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, topInset + 16)
            .padding(.bottom, 20)
            .environment(\.hudScale, scale)
        }
        // One curve for everything. Long and well damped, because it covers a
        // screen of travel and anything snappier reads as a snap rather than an
        // expansion.
        .animation(.spring(response: 0.52, dampingFraction: 0.86), value: visible)
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


                Button(action: onExit) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.visor)
                .help("Back to the notch — Esc, or \(ShortcutSettings.hint(.hud))")
            }

            HUDTranscript(chat: chat)

            HUDComposer(chat: chat)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Panels

    /// Each panel is the real feature, not a view of it.
    @ViewBuilder
    private func panelContent(_ panel: HUDPanel) -> some View {
        switch panel {
        case .agents:    agentsPanel
        case .tasks:     HUDTasksPanel(store: store, chat: chat, scale: scale)
        case .chats:     HUDChatsPanel(chat: chat, scale: scale)
        case .memory:    memoryPanel
        case .dictation: dictationPanel
        case .none:      EmptyView()
        }
    }

    private var agentsPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            if chat.chatAgents.isEmpty {
                Text("No agents yet.")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.3))
            }
            ForEach(Array(chat.chatAgents.enumerated()), id: \.element.id) { index, agent in
                Button { chat.use(agent) } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(agent.name == chat.agent?.name
                                  ? Color.orange : Color.white.opacity(0.22))
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
                            Text(ShortcutSettings.agentHint(index))
                                .font(.system(size: 8 * scale, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.22))
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control)
                        .fill(agent.name == chat.agent?.name
                              ? Design.Surface.hover : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.visorBare)
            }
        }
    }

    @ViewBuilder
    private var memoryPanel: some View {
        if !chat.graph.isEnabled {
            Text("Off. Turn it on in Settings → Memory and Visor starts learning from your conversations.")
                .font(.system(size: 10 * scale))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let top = chat.graph.prominent(limit: 8)
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

    @ViewBuilder
    private var dictationPanel: some View {
        let recent = VoiceLog.recent(limit: 6)
        let _ = voiceRefresh   // re-reads when an entry is deleted
        if recent.isEmpty {
            Text("Nothing dictated yet.")
                .font(.system(size: 11 * scale))
                .foregroundStyle(.white.opacity(0.3))
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(recent) { entry in
                    HUDVoiceRow(entry: entry, scale: scale) {
                        VoiceLog.delete(entry.id)
                        // Nudges the panel to re-read the log.
                        voiceRefresh &+= 1
                    }
                }
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
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .stroke(Design.Surface.hairline, lineWidth: 1))
    }
}

/// The composer, wider and taller than in the notch but the same control.
private struct HUDComposer: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text("Message \(chat.agent?.name ?? "your agent")…")
                        // Matches the field's own point size — at full screen the
                        // old 13pt read as a caption against everything else.
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.3))
                        .allowsHitTesting(false)
                }
                ComposerField(text: $chat.draft, onSubmit: chat.send, fontSize: 15)
            }
            .frame(height: 66)

            // A hairline between the message and its controls, so the row of
            // pickers reads as a toolbar for the field above rather than a
            // second thing floating in the same box.
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)

            HStack(spacing: 8) {
                // Gated exactly as the notch composer is. Ungated, the HUD
                // offered OpenRouter's whole catalogue to a Claude Code agent
                // — hundreds of models it has no way to run, from providers
                // that have nothing to do with the subscription it's using.
                // Two composers for one conversation is two places to get this
                // right, and this was the one that got missed.
                if chat.agent?.isChat ?? false {
                    InlineModelPicker(chat: chat)
                    EffortPicker(chat: chat)
                    FastToggle(chat: chat)
                } else if chat.isCLIAgent {
                    CLIModelPicker(chat: chat)
                }
                if chat.isStreaming {
                    DotMatrixIndicator(size: 11)
                    Text("working").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
                Button(action: chat.isStreaming ? chat.stop : chat.send) {
                    Image(systemName: chat.isStreaming
                          ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(chat.isStreaming ? Color.orange
                                         : (canSend ? Color.white : Color.white.opacity(0.25)))
                }
                .buttonStyle(.visorBare)
                .disabled(!chat.isStreaming && !canSend)
                // No ⌘↩ here: the field already sends on Return, and the notch
                // composer (mounted at the same time) owns that chord — two
                // views claiming it is how you get a shortcut that fires twice.
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .fill(Design.Surface.raised))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private var canSend: Bool {
        !chat.isStreaming
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.visor)
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
        .background(RoundedRectangle(cornerRadius: Design.Radius.pill).fill(.white.opacity(0.04)))
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
                .foregroundStyle(chat.isFavourite(id) ? Color.orange : Color.secondary.opacity(0.45))
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
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(.black.opacity(0.35)))
            }

            HStack(spacing: 6) {
                Button("Allow", action: allow)
                    .buttonStyle(.visorBare)
                    .composerPill(active: true)
                Button("Always", action: allowAlways)
                    .buttonStyle(.visorBare)
                    .composerPill()
                Button("Deny", action: deny)
                    .buttonStyle(.visorBare)
                    .composerPill()
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: Design.Radius.pill).fill(.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.pill).stroke(.orange.opacity(0.28), lineWidth: 1))
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
