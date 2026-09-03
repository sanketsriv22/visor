import AppKit
import SwiftUI

/// The floating box you drive general computer use from — type a task, run it,
/// watch the steps, stop it. A borderless panel that floats over everything so
/// you can see the agent work on whatever's underneath.
@MainActor
final class ComputerUseUI {
    static let shared = ComputerUseUI()
    private var panel: NSPanel?

    func toggle() { (panel?.isVisible ?? false) ? hide() : show() }

    func show() {
        let p = ensurePanel()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - 90))
        }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { panel?.orderOut(nil) }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: ComputerUseView(onClose: { [weak self] in self?.hide() }))
        panel = p
        return p
    }
}

private struct ComputerUseView: View {
    @ObservedObject private var agent = ComputerUseAgent.shared
    let onClose: () -> Void
    @State private var task = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                RetroIcon(Glyph.computer, size: 12, color: Design.Retro.accent)
                Text("COMPUTER USE")
                    .font(.custom(Design.Text.face, size: 12)).tracking(2)
                    .foregroundStyle(Design.Retro.text)
                Spacer()
                Button(action: onClose) {
                    RetroIcon(Glyph.close, size: 12, color: Design.Retro.dim)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                TextField("Tell your Mac what to do…", text: $task)
                    .textFieldStyle(.plain)
                    .font(.custom(Design.Text.face, size: 15))
                    .foregroundStyle(Design.Retro.text)
                    .onSubmit(run)
                if agent.running {
                    Button("Stop", action: agent.stop).tint(.red)
                } else {
                    Button("Run", action: run)
                        .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                .fill(Design.Retro.panel))
            .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                .stroke(Design.Retro.line, lineWidth: 1))

            HStack(spacing: 6) {
                if agent.running { DotMatrixIndicator(size: 9) }
                Text(agent.status)
                    .font(.custom(Design.Text.face, size: 10))
                    .foregroundStyle(agent.running ? Design.Retro.accent : Design.Retro.dim)
                    .lineLimit(1)
            }

            if !agent.log.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(agent.log.suffix(5).enumerated()), id: \.offset) { _, line in
                        Text("› \(line)")
                            .font(.custom(Design.Text.face, size: 10))
                            .foregroundStyle(Design.Retro.faint)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(15)
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Design.Retro.bg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Design.Retro.line, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private func run() {
        guard !agent.running else { return }
        agent.start(task)
    }
}
