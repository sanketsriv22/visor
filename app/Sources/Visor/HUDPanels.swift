import SwiftUI
import AppKit

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
        case .dictation: return "Voice log"
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

    /// Panels folded to their header, remembered.
    @Published private(set) var collapsed: Set<HUDPanel> {
        didSet { UserDefaults.standard.set(collapsed.map(\.rawValue), forKey: Self.collapsedKey) }
    }
    private static let collapsedKey = "visor.hud.collapsed"

    init() {
        var left = Self.load(Self.leftKey, fallback: [.agents, .chats])
        var right = Self.load(Self.rightKey, fallback: [.tasks, .memory])
        // A panel appears once. Two agent lists in the default arrangement
        // was the single biggest reason the HUD read as clutter; a user can
        // still choose the same panel twice deliberately, but a saved layout
        // that doubled up by accident is repaired here.
        var seen = Set<HUDPanel>()
        func dedupe(_ panels: [HUDPanel]) -> [HUDPanel] {
            panels.map { panel in
                guard panel != .none else { return panel }
                if seen.contains(panel) { return .none }
                seen.insert(panel)
                return panel
            }
        }
        left = dedupe(left)
        right = dedupe(right)
        self.left = left
        self.right = right
        let raw = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
        collapsed = Set(raw.compactMap(HUDPanel.init(rawValue:)))
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

    func isCollapsed(_ panel: HUDPanel) -> Bool { collapsed.contains(panel) }

    func toggleCollapsed(_ panel: HUDPanel) {
        if collapsed.contains(panel) { collapsed.remove(panel) } else { collapsed.insert(panel) }
    }

    enum Side { case left, right }
}

/// One panel on a rail: a header that doubles as the panel picker, a
/// collapse control, and the panel itself — sized to what it holds. A rail
/// used to stretch every panel to full height and box it in a border; the
/// boxes were most of what the eye saw.
struct HUDPanelSlot<Content: View>: View {
    let panel: HUDPanel
    var collapsed = false
    let onPick: (HUDPanel) -> Void
    var onToggle: () -> Void = {}
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: collapsed ? 0 : Design.Space.normal) {
            HStack(spacing: Design.Space.snug) {
                Menu {
                    ForEach(HUDPanel.allCases) { option in
                        Button { onPick(option) } label: {
                            Label(option.title, systemImage: option.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: Design.Space.snug) {
                        Self.headerIcon(for: panel)
                        SectionLabel(panel.title)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Design.Ink.faint)
                    }
                    .frame(height: Design.Metric.small)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose what this panel shows")

                Spacer(minLength: 0)

                IconButton(symbol: collapsed ? "chevron.left" : "chevron.down",
                           size: Design.Metric.small, tint: Design.Ink.faint,
                           help: collapsed ? "Expand" : "Collapse", action: onToggle)
                    .accessibilityIdentifier("visor.hud.panel.toggle")
            }

            if !collapsed {
                content()
            }
        }
        .padding(.horizontal, Design.Space.roomy)
        .padding(.vertical, Design.Space.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
            .fill(Design.Surface.rail))
        .animation(Design.Motion.animation(Design.Motion.standard), value: collapsed)
        .accessibilityIdentifier("visor.hud.panel.\(panel.rawValue)")
    }

    /// The rail's leading glyph. Tasks get the Visor mark itself — the panel
    /// writes to the same note the notch edits.
    @ViewBuilder
    static func headerIcon(for panel: HUDPanel) -> some View {
        if panel == .tasks, let mark = hudVisorMark {
            Image(nsImage: mark)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 10, height: 10)
                .foregroundStyle(Design.Ink.tertiary)
        } else {
            Image(systemName: panel.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Design.Ink.tertiary)
        }
    }
}

/// The bundled trefoil, tinted from its alpha like the notch's own mark.
///
/// A free function's `let` rather than a static on `HUDPanelSlot`: that type is
/// generic over its content, and generic types can't hold stored statics.
private let hudVisorMark: NSImage? = {
    guard let img = NSImage(named: "trefoilTemplate") else { return nil }
    img.isTemplate = true
    return img
}()

/// The task panel — the tasks themselves, not a picture of them.
///
/// Add, cycle, complete and delete all write to the same note the notch edits,
/// because a panel you can only look at is a worse version of the thing it's
/// showing.
/// What can hold keyboard focus in the task rail.
private enum HUDTaskFocus: Hashable { case add, row(UUID) }

/// Measures each row's laid-out height so the drag engine can reorder
/// multi-line rows without the lifted row drifting off the cursor.
private struct HUDRowHeightKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct HUDTasksPanel: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var chat: ChatController
    let scale: Double

    @State private var draft = ""
    @FocusState private var focus: HUDTaskFocus?
    @State private var showCompleted = false

    // Drag-to-reorder — the same engine the notch card runs: the lifted row
    // tracks the cursor while its neighbours spring into the slot it left.
    @State private var draggingID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var lastDY: CGFloat = 0
    @State private var rowHeights: [UUID: CGFloat] = [:]

    private let reorderSpring = Animation.spring(response: 0.34, dampingFraction: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            addField

            ForEach($store.items) { $item in
                if item.isTask && !item.done { row($item) }
            }

            completedSection

            if !store.items.contains(where: { $0.isTask && !$0.done }) {
                Text("Nothing open.")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 2)
            }
        }
        .onPreferenceChange(HUDRowHeightKey.self) { rowHeights = $0 }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 9 * scale))
                .foregroundStyle(.white.opacity(0.35))
            TextField("Add a task…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12 * scale))
                .foregroundStyle(.white.opacity(0.9))
                .focused($focus, equals: .add)
                .onSubmit(add)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Design.Radius.pill).fill(Design.Surface.raised))
    }

    @ViewBuilder
    private func row(_ binding: Binding<NoteItem>) -> some View {
        let item = binding.wrappedValue
        HUDTaskRow(
            item: binding,
            scale: scale,
            focus: $focus,
            isDragging: draggingID == item.id,
            onCycle:    { store.cycle(item.id); store.saveNow() },
            onComplete: { withAnimation(reorderSpring) { store.toggleDone(item.id) }; store.saveNow() },
            onDelete:   { withAnimation(reorderSpring) { store.remove(item.id) }; store.saveNow() },
            onCommit:   { store.saveNow() },
            onSubmit:   {
                let id = store.insertTask(after: item.id)
                store.saveNow()
                focus = .row(id)
            },
            onSend:       { chat.sendTaskToDefault(store.items.first { $0.id == item.id }?.text ?? "", id: item.id) },
            onOpenLink:   { openOrAddLink(for: item.id) },
            onEditLink:   { promptForLink(for: item.id) },
            onRemoveLink: { store.setLink(nil, for: item.id); store.saveNow() },
            otherNotes:   store.noteNames.filter { $0 != store.activeName },
            onMove:       { name in withAnimation(reorderSpring) { store.moveTask(item.id, toNote: name) }; store.saveNow() },
            onMoveToNew:  { withAnimation(reorderSpring) { store.moveTaskToNewNote(item.id) }; store.saveNow() },
            onDragChanged: { dy in dragChanged(item.id, dy) },
            onDragEnded:   { dragEnded() }
        )
        .background(GeometryReader { g in
            Color.clear.preference(key: HUDRowHeightKey.self, value: [item.id: g.size.height])
        })
        // The lifted row tracks the cursor with no animation (its slot jumps are
        // cancelled by dragOffset); every other row springs to its new slot.
        .scaleEffect(draggingID == item.id ? 1.03 : 1, anchor: .leading)
        .shadow(color: .black.opacity(draggingID == item.id ? 0.5 : 0),
                radius: draggingID == item.id ? 10 : 0, y: 4)
        .offset(y: draggingID == item.id ? dragOffset : 0)
        .zIndex(draggingID == item.id ? 1 : 0)
        .animation(draggingID == item.id ? nil : reorderSpring, value: store.items.map(\.id))
        .id(item.id)
    }

    /// Finished tasks collect behind a collapsible "N completed" toggle, exactly
    /// as they do on the notch card, so done work doesn't crowd the rail.
    @ViewBuilder
    private var completedSection: some View {
        let done = store.items.filter { $0.isTask && $0.done }
        if !done.isEmpty {
            Button {
                withAnimation(reorderSpring) { showCompleted.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8 * scale, weight: .semibold))
                    Text("\(done.count) completed")
                        .font(.system(size: 10 * scale, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.visor)
            .padding(.top, 4)

            if showCompleted {
                ForEach($store.items) { $item in
                    if item.isTask && item.done { row($item) }
                }
            }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        _ = store.addTask(text)
        store.saveNow()
        draft = ""
        focus = .add
    }

    // MARK: Drag engine (ported from the notch card)

    private func dragChanged(_ id: UUID, _ dy: CGFloat) {
        if draggingID != id { draggingID = id; lastDY = 0; dragOffset = 0 }
        dragOffset += dy - lastDY
        lastDY = dy
        // Swap into a neighbour's slot once the row has dragged past that
        // neighbour's midpoint, using the neighbour's measured height so the
        // threshold matches the slot the row actually crossed.
        while let idx = store.items.firstIndex(where: { $0.id == id }) {
            if idx < store.items.count - 1 {
                let h = slotHeight(of: store.items[idx + 1].id)
                if dragOffset > h / 2 { store.items.swapAt(idx, idx + 1); dragOffset -= h; continue }
            }
            if idx > 0 {
                let h = slotHeight(of: store.items[idx - 1].id)
                if dragOffset < -h / 2 { store.items.swapAt(idx, idx - 1); dragOffset += h; continue }
            }
            break
        }
    }

    private func dragEnded() {
        withAnimation(reorderSpring) { draggingID = nil; dragOffset = 0 }
        lastDY = 0
        store.saveNow()
    }

    private func slotHeight(of id: UUID) -> CGFloat { rowHeights[id] ?? (26 * scale) }

    // MARK: Links

    private func openOrAddLink(for id: UUID) {
        guard let idx = store.items.firstIndex(where: { $0.id == id }) else { return }
        if let raw = store.items[idx].link, let url = Self.normalizedURL(raw) {
            NSWorkspace.shared.open(url)
        } else {
            promptForLink(for: id)
        }
    }

    private func promptForLink(for id: UUID) {
        guard let idx = store.items.firstIndex(where: { $0.id == id }) else { return }
        let current = store.items[idx].link ?? ""
        let alert = NSAlert()
        alert.messageText = current.isEmpty ? "Add link" : "Edit link"
        alert.informativeText = "Paste a URL for this task. Leave it blank and save to remove the link."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: current)
        field.placeholderString = "https://example.com"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        // Above the HUD panel, which sits at .statusBar level.
        if let level = NSApp.keyWindow?.level {
            alert.window.level = NSWindow.Level(rawValue: level.rawValue + 1)
        }
        if alert.runModal() == .alertFirstButtonReturn {
            store.setLink(field.stringValue, for: id)
            store.saveNow()
        }
    }

    /// Add https:// to a bare host, and reject anything that still isn't a URL.
    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }
}

/// One task in the rail — the real item, editable in place, with everything the
/// notch card's row can do: reorder, status, complete, delete, send to an agent,
/// links, and moving it to another note.
private struct HUDTaskRow: View {
    @Binding var item: NoteItem
    let scale: Double
    var focus: FocusState<HUDTaskFocus?>.Binding
    var isDragging: Bool
    var onCycle: () -> Void
    var onComplete: () -> Void
    var onDelete: () -> Void
    var onCommit: () -> Void
    var onSubmit: () -> Void
    var onSend: () -> Void
    var onOpenLink: () -> Void
    var onEditLink: () -> Void
    var onRemoveLink: () -> Void
    var otherNotes: [String]
    var onMove: (String) -> Void
    var onMoveToNew: () -> Void
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void

    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Drag handle. Reserved width so the row doesn't shift when it fades
            // in on hover — the same complaint the voice log had.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9 * scale))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 12 * scale, height: 22 * scale)
                .contentShape(Rectangle())
                .opacity(hovering || isDragging ? 1 : 0)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { onDragChanged($0.translation.height) }
                        .onEnded { _ in onDragEnded() }
                )
                .help("Drag to reorder")

            // Cycles open → doing → blocked, as tapping does in the note.
            Button(action: onCycle) {
                Image(systemName: symbol)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(tint)
                    .frame(width: 20 * scale, height: 22 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.visor)
            .help("Change status")

            // Editable in place — the same item the notch edits.
            TextField("", text: $item.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * scale))
                .foregroundStyle(item.status == .done ? .white.opacity(0.4) : .white.opacity(0.85))
                .lineLimit(1...4)
                .focused(focus, equals: .row(item.id))
                .onSubmit(onSubmit)
                .onChange(of: focus.wrappedValue) { newFocus in
                    let now = newFocus == .row(item.id)
                    if editing && !now { onCommit() }   // saved once, when this row loses focus
                    editing = now
                }
                .padding(.top, 2 * scale)

            if item.link != nil {
                Image(systemName: "link")
                    .font(.system(size: 8 * scale))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 4 * scale)
            }
        }
        // The actions float over the trailing edge on a raised chip, so the
        // text never reflows when they appear.
        .overlay(alignment: .trailing) {
            if hovering && !isDragging {
                HStack(spacing: 1) {
                    action("paperplane", .white.opacity(0.55), onSend, "Send to agent")
                    action("checkmark", .green.opacity(0.85), onComplete,
                           item.status == .done ? "Reopen" : "Complete")
                    action("trash", .white.opacity(0.45), onDelete, "Delete")
                }
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: Design.Radius.pill).fill(Design.Surface.raised))
                .transition(.opacity)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.1)) { hovering = h } }
        .contextMenu { menu }
    }

    private func action(_ symbol: String, _ colour: Color,
                        _ act: @escaping () -> Void, _ help: String) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundStyle(colour)
                .frame(width: 20 * scale, height: 20 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.visorBare)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        if item.link == nil {
            Button("Add link…", action: onEditLink)
        } else {
            Button("Open link", action: onOpenLink)
            Button("Edit link…", action: onEditLink)
            Button("Remove link", action: onRemoveLink)
        }
        Divider()
        if otherNotes.isEmpty {
            Button("Move to new note", action: onMoveToNew)
        } else {
            Menu("Move to") {
                ForEach(otherNotes, id: \.self) { name in
                    Button(name) { onMove(name) }
                }
                Divider()
                Button("New note", action: onMoveToNew)
            }
        }
        Divider()
        Button("Send to agent", action: onSend)
        Button("Delete", role: .destructive, action: onDelete)
    }

    private var symbol: String {
        switch item.status {
        case .open:    return "circle"
        case .doing:   return "circle.lefthalf.filled"
        case .blocked: return "exclamationmark.circle.fill"
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
