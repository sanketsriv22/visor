import SwiftUI

/// The agent's identity, leading the chat card: a status dot, the name, the
/// model or account, and a chevron. One control that opens the agent
/// selector. The agent is the product, so this is the card's first line.
struct AgentIdentity: View {
    @ObservedObject var chat: ChatController
    @ObservedObject private var accounts = CLIAccounts.shared
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: Design.Space.normal) {
                StatusDot(state: chat.isStreaming ? .working : (chat.agent == nil ? .absent : .idle))
                Text(chat.agent?.name ?? "No agent")
                    .font(Design.Typography.heading())
                    .foregroundStyle(Design.Ink.primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(Design.Typography.secondary())
                        .foregroundStyle(Design.Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Design.Ink.faint)
            }
            .padding(.horizontal, Design.Space.normal)
            .frame(height: Design.Metric.regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.visor)
        .focusable(false)
        .help("Choose an agent")
        .accessibilityIdentifier("visor.chat.agent")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AgentSelector(chat: chat) { showing = false }
        }
    }

    /// The model for a hosted agent; for a local one, whose account it runs
    /// as — which matters more and is otherwise invisible.
    private var detail: String? {
        guard let agent = chat.agent else { return nil }
        if agent.isNotchCLI, let account = accounts.account(for: agent) { return account.summary }
        return chat.shortModelName.isEmpty ? nil : chat.shortModelName
    }
}

/// Six points of state: idle, working (breathing accent), absent.
struct StatusDot: View {
    enum State { case idle, working, absent }
    let state: State

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: state != .working || Design.Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = state == .working && !Design.Motion.reduced ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 3.2)) : 1
            Circle()
                .fill(colour)
                .frame(width: 6, height: 6)
                .opacity(breath)
                .shadow(color: state == .working ? Design.Retro.accent.opacity(0.6) : .clear, radius: 4)
        }
        .frame(width: 8, height: 8)
    }

    private var colour: Color {
        switch state {
        case .idle:    return Color.white.opacity(0.45)
        case .working: return Design.Retro.accent
        case .absent:  return Design.Ink.faint
        }
    }
}

/// The agent selector: every agent with what it runs on, the current one
/// checked, and the way to the full settings.
struct AgentSelector: View {
    @ObservedObject var chat: ChatController
    @ObservedObject private var accounts = CLIAccounts.shared
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SelectorHeading(title: "Agents")
            SelectorList(rows: rows, emptyText: "No agents yet. Add one in Settings.", maxHeight: 300) { id in
                if let agent = chat.chatAgents.first(where: { $0.name == id }) { chat.use(agent) }
                dismiss()
            }
            Divider().overlay(Design.Stroke.divider)
            HStack {
                Button {
                    NotificationCenter.default.post(name: .visorOpenSettings, object: nil)
                    dismiss()
                } label: {
                    HStack(spacing: Design.Space.snug) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: Design.Metric.iconSmall, weight: .medium))
                        Text("Manage agents…").font(Design.Typography.secondaryMedium())
                    }
                    .foregroundStyle(Design.Ink.secondary)
                    .padding(.horizontal, Design.Space.normal)
                    .frame(height: Design.Metric.regular)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.visor)
                .focusable(false)
                Spacer()
            }
            .padding(Design.Space.snug)
        }
        .selectorSurface(width: 300)
    }

    private var rows: [SelectorRow] {
        chat.chatAgents.map { agent in
            let sub: String
            if agent.isNotchCLI {
                sub = accounts.account(for: agent)?.summary ?? agent.command
            } else {
                sub = agent.model ?? ChatController.defaultModel
            }
            return SelectorRow(id: agent.name, title: agent.name, subtitle: sub,
                               mark: agent.isNotchCLI ? Design.Ink.secondary : Design.Retro.accent,
                               selected: agent.name == chat.agent?.name)
        }
    }
}

/// The empty transcript: what Visor is for, and three things to try that
/// land in the composer. Notes don't appear here — they're a supporting
/// capability, not the invitation.
struct EmptyInvitation: View {
    @ObservedObject var chat: ChatController
    var scale: Double = 1

    private static let examples = [
        "Explain what's on my screen",
        "Tidy my Desktop into folders by type",
        "Draft a reply to my last email",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            if chat.chatAgents.isEmpty {
                Text("Connect an agent to start.")
                    .font(Design.Typography.heading(scale))
                    .foregroundStyle(Design.Ink.primary)
                Text("Any model through OpenRouter with a key, or Claude Code, Codex and Devin already on your Mac.")
                    .font(Design.Typography.secondary(scale))
                    .foregroundStyle(Design.Ink.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                ActionChip(title: "Open Settings", prominent: true) {
                    NotificationCenter.default.post(name: .visorOpenSettings, object: nil)
                }
                .accessibilityIdentifier("visor.empty.settings")
            } else {
                Text("Ask \(chat.agent?.name ?? "your agent") for help, or hand it a task.")
                    .font(Design.Typography.heading(scale))
                    .foregroundStyle(Design.Ink.primary)
                Text("It can read your screen, run commands, and drive your Mac. ⌘ . stops it at any point.")
                    .font(Design.Typography.secondary(scale))
                    .foregroundStyle(Design.Ink.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Design.Space.snug) {
                    ForEach(Self.examples, id: \.self) { example in
                        ExampleChip(text: example) { chat.draft = example }
                    }
                }
                .padding(.top, Design.Space.tight)
                .accessibilityIdentifier("visor.empty.examples")
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}
