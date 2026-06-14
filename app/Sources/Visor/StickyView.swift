import SwiftUI

struct StickyRootView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var ui: UIState
    @ObservedObject var devin: DevinRunner
    var onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NotchStrip(
                size: ui.notchSize,
                expanded: ui.expanded
            )
            if ui.expanded {
                StickyCard(store: store, devin: devin, onClose: onToggle)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
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
    @ObservedObject var devin: DevinRunner
    var onClose: () -> Void

    @FocusState private var focused: UUID?
    @State private var newTask = ""
    private let addFieldID = UUID()

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 18,
            topTrailingRadius: 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("VISOR")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.openTaskCount) open")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.openTaskCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            taskList

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(width: NotchController.cardWidth, height: NotchController.cardHeight)
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

    private var taskList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach($store.items) { $item in
                    NoteRow(
                        item: $item,
                        focused: $focused,
                        onToggle: { store.toggle(item.id) },
                        onSubmit: { focusRow(store.insertTask(after: item.id)) },
                        onDelete: { store.remove(item.id) }
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

    private var footer: some View {
        HStack(spacing: 8) {
            statusLabel
            Spacer(minLength: 8)
            devinButton
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch devin.status {
        case .idle:
            Text("click ○ to complete")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        case .running:
            Label("Devin working…", systemImage: "circle.dotted")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .done:
            Button(action: devin.revealLog) {
                Label("Devin finished — view log", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        case .failed(let why):
            Button(action: devin.revealLog) {
                Label("Devin failed (\(why))", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private var devinButton: some View {
        let busy = devin.status == .running
        let enabled = store.openTaskCount > 0 && !busy
        return Button {
            devin.send(tasks: store.openTasks)
        } label: {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    Image(systemName: "paperplane.fill")
                }
                Text(busy ? "Sending" : "Send to Devin")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(enabled ? Color.orange : Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(store.openTaskCount == 0 ? "No open tasks to send" : "Send open tasks to Devin")
    }
}

/// A single editable line: a clickable checkbox + inline text for tasks, or
/// plain text otherwise. A delete affordance appears on hover.
private struct NoteRow: View {
    @Binding var item: NoteItem
    @FocusState.Binding var focused: UUID?
    var onToggle: () -> Void
    var onSubmit: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if item.isTask {
                Button(action: onToggle) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(item.done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
            }

            TextField("", text: $item.text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .strikethrough(item.isTask && item.done, color: .secondary)
                .foregroundStyle(item.isTask && item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .focused($focused, equals: item.id)
                .onSubmit(onSubmit)

            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
    }
}
