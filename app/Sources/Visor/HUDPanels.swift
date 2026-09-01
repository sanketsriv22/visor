import SwiftUI

/// What a HUD rail can show.
///
/// The HUD started as three fixed rails, which made it a viewer for features
/// that lived properly elsewhere. Each of these is the real thing — the task
/// panel writes to the same note the notch does — and which panels appear is
/// the user's choice, because a screen-sized surface should show what *they*
/// need at a glance rather than what happened to be built first.
enum HUDPanel: String, CaseIterable, Identifiable, Codable {
    case agents, tasks, chats, memory, dictation, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents:    return "Agents"
        case .tasks:     return "Tasks"
        case .chats:     return "Past chats"
        case .memory:    return "What I know"
        case .dictation: return "Recently said"
        case .none:      return "Empty"
        }
    }

    var symbol: String {
        switch self {
        case .agents:    return "person.2"
        case .tasks:     return "checklist"
        case .chats:     return "clock.arrow.circlepath"
        case .memory:    return "brain"
        case .dictation: return "waveform"
        case .none:      return "minus"
        }
    }
}

/// Which panels sit where, remembered between sessions.
@MainActor
final class HUDLayout: ObservableObject {
    @Published var left: [HUDPanel] { didSet { save() } }
    @Published var right: [HUDPanel] { didSet { save() } }

    private static let leftKey = "visor.hud.left"
    private static let rightKey = "visor.hud.right"

    init() {
        left = Self.load(Self.leftKey, fallback: [.agents, .memory])
        right = Self.load(Self.rightKey, fallback: [.tasks, .chats])
    }

    private static func load(_ key: String, fallback: [HUDPanel]) -> [HUDPanel] {
        guard let raw = UserDefaults.standard.stringArray(forKey: key) else { return fallback }
        let panels = raw.compactMap(HUDPanel.init(rawValue:))
        return panels.isEmpty ? fallback : panels
    }

    private func save() {
        UserDefaults.standard.set(left.map(\.rawValue), forKey: Self.leftKey)
        UserDefaults.standard.set(right.map(\.rawValue), forKey: Self.rightKey)
    }

    func set(_ panel: HUDPanel, side: Side, index: Int) {
        switch side {
        case .left where left.indices.contains(index):   left[index] = panel
        case .right where right.indices.contains(index): right[index] = panel
        default: break
        }
    }

    enum Side { case left, right }
}

/// One rail: a header that doubles as the panel picker, and the panel itself.
struct HUDPanelSlot<Content: View>: View {
    let panel: HUDPanel
    let scale: Double
    let onPick: (HUDPanel) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(HUDPanel.allCases) { option in
                    Button {
                        onPick(option)
                    } label: {
                        Label(option.title, systemImage: option.symbol)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: panel.symbol)
                        .font(.system(size: 8 * scale, weight: .semibold))
                    Text(panel.title.uppercased())
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .tracking(0.8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6 * scale, weight: .bold))
                        .opacity(0.6)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.4))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            content()
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .stroke(Design.Surface.hairline, lineWidth: 1))
    }
}

/// The task panel — the tasks themselves, not a picture of them.
///
/// Add, cycle, complete and delete all write to the same note the notch edits,
/// because a panel you can only look at is a worse version of the thing it's
/// showing.
struct HUDTasksPanel: View {
    @ObservedObject var store: NotesStore
    let scale: Double

    @State private var draft = ""
    @FocusState private var adding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 9 * scale))
                    .foregroundStyle(.white.opacity(0.35))
                TextField("Add a task…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(.white.opacity(0.9))
                    .focused($adding)
                    .onSubmit(add)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Design.Radius.pill).fill(Design.Surface.raised))

            ForEach(store.items.filter { $0.isTask && !$0.done }.prefix(14)) { item in
                HUDTaskRow(item: item, scale: scale, store: store)
            }

            if store.items.filter({ $0.isTask && !$0.done }).isEmpty {
                Text("Nothing open.")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 2)
            }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        _ = store.addTask(text)
        store.saveNow()
        draft = ""
        adding = true
    }
}

private struct HUDTaskRow: View {
    let item: NoteItem
    let scale: Double
    @ObservedObject var store: NotesStore

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Cycles open -> doing -> blocked, as tapping does in the note.
            Button {
                store.cycle(item.id)
                store.saveNow()
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(tint)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.visor)
            .help("Change status")

            Text(item.text)
                .font(.system(size: 13 * scale))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(3)
                .padding(.top, 3 * scale)

            Spacer(minLength: 0)

            if hovering {
                // Completing is its own button here rather than a long-press:
                // a gesture you can't see isn't discoverable on a surface
                // you're meant to glance at.
                Button {
                    store.toggleDone(item.id)
                    store.saveNow()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundStyle(.green.opacity(0.85))
                        .frame(width: 20 * scale, height: 20 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.visor)
                .help("Complete")

                Button {
                    store.remove(item.id)
                    store.saveNow()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10 * scale))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 20 * scale, height: 20 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.visor)
                .help("Delete")
            }
        }
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        switch item.status {
        case .open:    return "circle"
        case .doing:   return "circle.lefthalf.filled"
        case .blocked: return "exclamationmark.circle"
        case .done:    return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch item.status {
        case .open:    return .white.opacity(0.35)
        case .doing:   return .orange
        case .blocked: return .red.opacity(0.8)
        case .done:    return .green.opacity(0.8)
        }
    }
}

/// Past chats, openable and deletable.
struct HUDChatsPanel: View {
    @ObservedObject var chat: ChatController
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if chat.store.summaries.isEmpty {
                Text("No saved chats yet.")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.3))
            }
            ForEach(chat.store.summaries.prefix(12)) { row in
                HUDChatRow(summary: row, scale: scale,
                           isCurrent: row.id == chat.conversation.id,
                           open: { chat.open(row.id) },
                           delete: { chat.delete(row.id) })
            }
        }
    }
}

private struct HUDChatRow: View {
    let summary: ConversationSummary
    let scale: Double
    let isCurrent: Bool
    let open: () -> Void
    let delete: () -> Void

    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isCurrent ? Color.orange : .clear)
                        .frame(width: 2, height: 20 * scale)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary.title.isEmpty ? "Untitled" : summary.title)
                            .font(.system(size: 12 * scale,
                                          weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                        Text("\(summary.agentName) · \(summary.messageCount)")
                            .font(.system(size: 9 * scale))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.visor)

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
                                .font(.system(size: 10 * scale, weight: .semibold))
                                .foregroundStyle(.red.opacity(0.95))
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 10 * scale))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(height: 20 * scale)
                    .padding(.horizontal, confirming ? 6 : 0)
                    .frame(minWidth: 20 * scale)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control)
                        .fill(confirming ? Color.red.opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.visorBare)
                .help(confirming ? "Click again to delete" : "Delete this chat")
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
    }
}
