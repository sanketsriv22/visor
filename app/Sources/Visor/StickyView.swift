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
                Text("STICKIES")
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

            TextEditor(text: $store.text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(0.55), radius: 20, y: 10)
        )
        .overlay(
            shape.strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .onExitCommand(perform: onClose)
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
            Text("- [ ] makes a task")
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
