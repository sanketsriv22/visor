import SwiftUI

struct StickyRootView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var ui: UIState
    @ObservedObject var ai: AIRunner
    var onToggle: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if ui.expanded {
                // The card extends up behind the notch (topInset) so the notch
                // overlaps its top edge — the note looks like it slides out
                // from *behind* the notch, not off its bottom lip.
                StickyCard(store: store, ai: ai, topInset: ui.notchSize.height, notchWidth: ui.notchSize.width, suppressHover: ui.settling, onClose: onToggle)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                NotchStrip(size: ui.notchSize, expanded: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Hit target over the notch (clicks are handled by the controller's
/// mouse-down monitor, not gestures). On hover while collapsed, the notch
/// appears to grow downward slightly — drawn in the underhang band below
/// the physical notch, since pixels inside the notch rect don't exist.
private struct NotchStrip: View {
    let size: CGSize
    let expanded: Bool

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if hovering && !expanded {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 8,
                    bottomTrailingRadius: 8,
                    topTrailingRadius: 0
                )
                .fill(Color.black)
                Capsule()
                    .fill(.white.opacity(0.5))
                    .frame(width: size.width * 0.4, height: 2.5)
                    .padding(.bottom, 3)
            } else {
                Color.black.opacity(0.011) // effectively invisible, still hit-testable
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct StickyCard: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var ai: AIRunner
    /// Height of the notch the card tucks up behind; content starts below it.
    var topInset: CGFloat
    /// Width of the notch, so the top band can flank it instead of overlapping.
    var notchWidth: CGFloat
    /// Suppress per-row hover affordances while the card animates open.
    var suppressHover: Bool
    var onClose: () -> Void

    @FocusState private var focused: UUID?
    @State private var newTask = ""
    private let addFieldID = UUID()
    private let titleFieldID = UUID()

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 18,
            topTrailingRadius: 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            notchBand

            HStack(spacing: 8) {
                Menu {
                    ForEach(store.noteNames, id: \.self) { name in
                        Button { store.switchTo(name) } label: {
                            if name == store.activeName {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                    Divider()
                    Button("New note", action: store.newNote)
                } label: {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Switch or create notes")

                TextField("Name this note…", text: $store.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($focused, equals: titleFieldID)
                    .onSubmit { store.commitTitle() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)

            taskList

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(width: NotchController.cardWidth, height: NotchController.cardHeight + topInset)
        .background(
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        )
        .overlay(
            shape.strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .onExitCommand(perform: onClose)
    }

    /// The strip at notch height: VISOR in the left shoulder, open-count in the
    /// right shoulder, with a gap in the middle cleared for the physical notch.
    private var notchBand: some View {
        let gap = notchWidth + 18 // notch + a little clearance on each side
        let shoulder = max(0, (NotchController.cardWidth - gap) / 2)
        return HStack(spacing: 0) {
            Text("VISOR")
                .font(.system(size: 11, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
                .frame(width: shoulder, alignment: .leading)
            Spacer(minLength: 0).frame(width: gap)
            Text("\(store.openTaskCount) open")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(store.openTaskCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(.trailing, 16)
                .frame(width: shoulder, alignment: .trailing)
        }
        .frame(height: topInset)
    }

    private var taskList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach($store.items) { $item in
                    NoteRow(
                        item: $item,
                        focused: $focused,
                        suppressHover: suppressHover,
                        isSending: ai.isRunning(item.id),
                        onToggle: { store.cycle(item.id) },
                        onSubmit: { focusRow(store.insertTask(after: item.id)) },
                        onDelete: { store.remove(item.id) },
                        onSend: {
                            let t = item.text.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty { ai.sendToDefault(tasks: [t], taskIDs: [item.id]) }
                        },
                        onDropDragged: { draggedID in
                            withAnimation(.easeInOut(duration: 0.18)) {
                                store.move(id: draggedID, toIndexOf: item.id)
                            }
                        }
                    )
                }
                addRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("Add a task…", text: $newTask)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused, equals: addFieldID)
                .onSubmit(commitNewTask)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { focused = addFieldID }
    }

    private func commitNewTask() {
        let trimmed = newTask.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addTask(trimmed)
        newTask = ""
        focused = addFieldID // stay in the add field for rapid entry
    }

    private func focusRow(_ id: UUID) {
        DispatchQueue.main.async { focused = id }
    }

    // Sending is per-task (the ✈ on each row), and runs are concurrent. The
    // footer shows how many are running, else the last run's result. Which
    // agent it goes to is set in the menu-bar settings.
    @ViewBuilder
    private var footer: some View {
        if ai.runningCount > 0 {
            Label(ai.runningCount == 1 ? "\(ai.lastProviderName) working…" : "\(ai.runningCount) agents working…",
                  systemImage: "circle.dotted")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else {
            switch ai.lastResult {
            case .none:
                Text("hover a task → ✈ sends it to \(ai.defaultProviderName)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            case .done:
                Button(action: ai.revealLog) {
                    Label("\(ai.lastProviderName) finished — view log", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            case .failed(let why):
                Button(action: ai.revealLog) {
                    Label("\(ai.lastProviderName) failed (\(why))", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A single editable line: a clickable checkbox + inline text for tasks, or
/// plain text otherwise. A delete affordance appears on hover.
private struct NoteRow: View {
    @Binding var item: NoteItem
    @FocusState.Binding var focused: UUID?
    var suppressHover: Bool
    var isSending: Bool
    var onToggle: () -> Void
    var onSubmit: () -> Void
    var onDelete: () -> Void
    var onSend: () -> Void
    var onDropDragged: (UUID) -> Void

    @State private var hovering = false
    @State private var dropTargeted = false

    static func glyph(_ s: TaskStatus) -> String {
        switch s {
        case .open: return "circle"
        case .doing: return "circle.lefthalf.filled"
        case .blocked: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    static func tint(_ s: TaskStatus) -> AnyShapeStyle {
        switch s {
        case .open: return AnyShapeStyle(.secondary)
        case .doing: return AnyShapeStyle(.blue)
        case .blocked: return AnyShapeStyle(.red)
        case .done: return AnyShapeStyle(.green)
        }
    }

    static func label(_ s: TaskStatus) -> String {
        switch s {
        case .open: return "Open"
        case .doing: return "Doing"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }

    var body: some View {
        // .top alignment keeps the handle, checkbox and delete button on the
        // first line when a long task wraps to multiple lines.
        HStack(alignment: .top, spacing: 8) {
            // Drag handle — only this grabs for reordering, so dragging never
            // fights with editing the task text.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .opacity((hovering && !suppressHover) ? 0.7 : 0.22)
                .draggable(item.id.uuidString)

            if item.isTask {
                Button(action: onToggle) {
                    Image(systemName: Self.glyph(item.status))
                        .font(.system(size: 14))
                        .foregroundStyle(Self.tint(item.status))
                }
                .buttonStyle(.plain)
                .help(Self.label(item.status) + " — click to change")
            }

            // axis: .vertical lets long text wrap onto new lines and the row
            // grow, instead of truncating on a single line.
            TextField("", text: $item.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .strikethrough(item.isTask && item.done, color: .secondary)
                .foregroundStyle(item.isTask && item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .focused($focused, equals: item.id)
                .onSubmit(onSubmit)

            // An agent is running for this task — show a spinner regardless of hover.
            if item.isTask && isSending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.orange)
                    .help("An agent is working on this task")
            }
            if hovering && !suppressHover {
                if item.isTask && !item.done && !isSending {
                    Button(action: onSend) {
                        Image(systemName: "paperplane")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Send just this task to the chosen agent")
                    .transition(.opacity)
                }
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .top) {
            // Insertion indicator while a drag hovers this row.
            if dropTargeted {
                Rectangle().fill(.orange).frame(height: 2).offset(y: -2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init) else { return false }
            onDropDragged(id)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}
