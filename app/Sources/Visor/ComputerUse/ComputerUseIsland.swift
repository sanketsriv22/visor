import AppKit
import SwiftUI

/// A borderless panel that can still take keyboard focus. Borderless panels
/// return false for `canBecomeKey` by default, which is why the task field
/// couldn't be typed into.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The box you drive general computer use from — type a task, run it, watch the
/// steps, stop it. A small card anchored under the notch, so it reads as one of
/// Visor's notch interfaces rather than a big island floating mid-screen.
@MainActor
final class ComputerUseUI {
    static let shared = ComputerUseUI()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let p = ensurePanel()
        if let screen = NSScreen.main {
            let f = screen.frame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - 8))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                             styleMask: [.borderless],
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
    @FocusState private var focused: Bool

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
                    .font(.custom(Design.Text.face, size: 14))
                    .foregroundStyle(Design.Retro.text)
                    .focused($focused)
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
        .padding(14)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Design.Retro.bg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Design.Retro.line, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func run() {
        guard !agent.running else { return }
        agent.start(task)
    }
}

/// Computer Use as a notch face — the card that slides out of the notch, the
/// same way Notes and Chat do, rather than a detached panel. It stays up for
/// the whole task: you type what you want, press ⏎, and the card reports each
/// step while the agent drives the rest of the desktop, so you always see what
/// it's doing. Backed by the shared `ComputerUseAgent`, so its state survives
/// view rebuilds and the card can be reopened mid-run.
struct ComputerUseCard: View {
    @ObservedObject private var agent = ComputerUseAgent.shared
    let topInset: CGFloat
    let notchWidth: CGFloat
    let onClose: () -> Void
    @State private var task = ""
    @State private var copied = false
    @AppStorage(ComputerUseAgent.modelKey) private var modelID = ComputerUseAgent.defaultModel
    @FocusState private var focused: Bool

    private var modelLabel: String {
        let name = ComputerUseAgent.models.first { $0.id == modelID }?.name ?? modelID
        return name.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: topInset)   // clear the physical notch
            VStack(alignment: .leading, spacing: 8) {
                header
                field
                statusLine
                logView
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            RetroIcon(Glyph.computer, size: 13, color: Design.Retro.accent)
            Text("COMPUTER USE")
                .font(.custom(Design.Text.face, size: 12)).tracking(2)
                .foregroundStyle(Design.Retro.text)
            Spacer()
            Menu {
                ForEach(ComputerUseAgent.models, id: \.id) { m in
                    Button(m.name) { modelID = m.id }
                }
            } label: {
                Text(modelLabel)
                    .font(.custom(Design.Text.face, size: 9)).tracking(1)
                    .foregroundStyle(Design.Retro.dim)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(agent.running)
            if agent.running {
                Button(action: agent.stop) {
                    Text("STOP")
                        .font(.custom(Design.Text.face, size: 10)).tracking(1)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            Button(action: onClose) {
                RetroIcon(Glyph.close, size: 12, color: Design.Retro.dim)
            }
            .buttonStyle(.plain)
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Tell your Mac what to do…", text: $task)
                .textFieldStyle(.plain)
                .font(.custom(Design.Text.face, size: 14))
                .foregroundStyle(Design.Retro.text)
                .focused($focused)
                .onSubmit(run)
                .disabled(agent.running)
            if !agent.running {
                Button("Run", action: run)
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
            .fill(Design.Retro.panel))
        .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
            .stroke(Design.Retro.line, lineWidth: 1))
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if agent.running { DotMatrixIndicator(size: 9) }
            Text(agent.status)
                .font(.custom(Design.Text.face, size: 11))
                .foregroundStyle(agent.running ? Design.Retro.accent : Design.Retro.dim)
                .lineLimit(1)
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("STEPS")
                    .font(.custom(Design.Text.face, size: 9)).tracking(2)
                    .foregroundStyle(Design.Retro.dim)
                Spacer()
                if !agent.log.isEmpty {
                    Button(action: copyLog) {
                        Text(copied ? "COPIED" : "COPY")
                            .font(.custom(Design.Text.face, size: 9)).tracking(1)
                            .foregroundStyle(copied ? Design.Retro.accent : Design.Retro.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if agent.log.isEmpty {
                            Text(agent.running ? "Starting…" : "No steps yet — type a task above and Run.")
                                .font(.custom(Design.Text.face, size: 11))
                                .foregroundStyle(Design.Retro.faint)
                        } else {
                            ForEach(Array(agent.log.enumerated()), id: \.offset) { i, line in
                                Text("\(i + 1). \(line)")
                                    .font(.custom(Design.Text.face, size: 11))
                                    .foregroundStyle(Design.Retro.text.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                    }
                    .padding(9)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 130, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                    .fill(Design.Retro.panel))
                .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                    .stroke(Design.Retro.line, lineWidth: 1))
                .onChange(of: agent.log.count) { _ in
                    if let last = agent.log.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func run() {
        guard !agent.running else { return }
        agent.start(task)
    }

    private func copyLog() {
        var lines = ["Task: \(task)", "Status: \(agent.status)", ""]
        lines += agent.log.enumerated().map { "\($0.offset + 1). \($0.element)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }
}
