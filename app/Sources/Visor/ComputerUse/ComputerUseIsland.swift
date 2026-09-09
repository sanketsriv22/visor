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
                    .font(Design.Text.f(12)).tracking(2)
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
                    .font(Design.Text.f(14))
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
                    .font(Design.Text.f(10))
                    .foregroundStyle(agent.running ? Design.Retro.accent : Design.Retro.dim)
                    .lineLimit(1)
            }

            if !agent.log.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(agent.log.suffix(5).enumerated()), id: \.offset) { _, line in
                        Text("› \(line)")
                            .font(Design.Text.f(10))
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

    private var canRun: Bool {
        !task.trimmingCharacters(in: .whitespaces).isEmpty && !agent.running
    }
    private var modelLabel: String {
        let name = ComputerUseAgent.models.first { $0.id == modelID }?.name ?? modelID
        return name.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: topInset)   // clear the physical notch
            VStack(alignment: .leading, spacing: Design.Space.roomy) {
                header
                field
                if agent.running || !agent.log.isEmpty { logSection } else { hint }
            }
            .padding(.horizontal, 14)
            .padding(.top, Design.Space.tight)
            .padding(.bottom, Design.Space.roomy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var header: some View {
        HStack(spacing: Design.Space.snug) {
            RetroIcon(Glyph.computer, size: 11, color: Design.Retro.accent)
            SectionLabel("Computer use", tint: Design.Ink.secondary)
            Spacer()
            Menu {
                ForEach(ComputerUseAgent.models, id: \.id) { m in
                    Button(m.name) { modelID = m.id }
                }
            } label: {
                HStack(spacing: Design.Space.tight) {
                    Text(modelLabel)
                        .font(Design.Typography.caption())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(Design.Ink.tertiary)
                .frame(height: Design.Metric.small)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(agent.running)
            .help("Model that drives the task")
            IconButton(symbol: "xmark", size: Design.Metric.small, tint: Design.Ink.tertiary,
                       help: "Close", action: onClose)
                .accessibilityIdentifier("visor.computerUse.close")
        }
    }

    /// The task, in the composer's own clothes: same surface, same radius,
    /// same round control on the right — run, or stop while it runs.
    private var field: some View {
        HStack(spacing: Design.Space.normal) {
            TextField("Tell your Mac what to do", text: $task)
                .textFieldStyle(.plain)
                .font(Design.Typography.body())
                .foregroundStyle(Design.Ink.primary)
                .focused($focused)
                .onSubmit { if canRun { agent.start(task) } }
                .disabled(agent.running)
                .accessibilityIdentifier("visor.computerUse.task")
            runButton
        }
        .padding(.leading, Design.Space.loose)
        .padding(.trailing, Design.Space.normal)
        .padding(.vertical, Design.Space.normal)
        .background(RoundedRectangle(cornerRadius: Design.Radius.composer, style: .continuous)
            .fill(Design.Surface.raisedStrong))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.composer, style: .continuous)
            .strokeBorder(agent.running ? Design.Retro.accent.opacity(0.55) : Design.Stroke.edge,
                          lineWidth: Design.Stroke.hairline))
    }

    private var runButton: some View {
        Button {
            if agent.running { agent.stop() } else if canRun { agent.start(task) }
        } label: {
            ZStack {
                Circle().fill(agent.running ? Design.Ink.destructive
                              : (canRun ? Design.Retro.accent : Color.white.opacity(0.1)))
                if agent.running {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: Design.Metric.iconLarge, weight: .bold))
                        .foregroundStyle(canRun ? Design.Retro.onAccent : Color.white.opacity(0.3))
                }
            }
            .frame(width: Design.Metric.large, height: Design.Metric.large)
            .contentShape(Circle())
        }
        .buttonStyle(.visorBare)
        .focusable(false)
        .disabled(!agent.running && !canRun)
        .help(agent.running ? "Stop — the agent halts before its next action" : "Run — ↩")
        .accessibilityIdentifier(agent.running ? "visor.computerUse.stop" : "visor.computerUse.run")
        .animation(Design.Motion.quick, value: agent.running)
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text("It reads the screen through Accessibility, then clicks and types for you. Watch every step here; stop it any time.")
                .font(Design.Typography.secondary())
                .foregroundStyle(Design.Ink.tertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.snug) {
                ExampleChip(text: "Open System Settings and turn on Night Shift") {
                    task = "Open System Settings and turn on Night Shift"
                }
                ExampleChip(text: "Find today's first meeting in Calendar") {
                    task = "Find today's first meeting in Calendar and tell me the time"
                }
            }
        }
        .padding(.top, Design.Space.tight)
    }

    /// What it is doing now, the steps so far, and the way to stop it —
    /// the three things a person watching an agent drive their Mac needs.
    private var logSection: some View {
        VStack(alignment: .leading, spacing: Design.Space.normal) {
            HStack(spacing: Design.Space.normal) {
                StatusDot(state: agent.running ? .working : .idle)
                Text(agent.status)
                    .font(Design.Typography.secondaryMedium())
                    .foregroundStyle(agent.running ? Design.Ink.primary : Design.Ink.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !agent.log.isEmpty {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", size: Design.Metric.small,
                               tint: copied ? Design.Retro.accent : Design.Ink.tertiary,
                               help: "Copy the run log", action: copyLog)
                        .accessibilityIdentifier("visor.computerUse.copy")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.tight) {
                        if agent.log.isEmpty {
                            Text(agent.running ? "Starting…" : "No steps yet.")
                                .font(Design.Typography.caption())
                                .foregroundStyle(Design.Ink.faint)
                        } else {
                            ForEach(Array(agent.log.enumerated()), id: \.offset) { i, line in
                                let latest = i == agent.log.count - 1
                                HStack(alignment: .top, spacing: Design.Space.normal) {
                                    Text("\(i + 1)")
                                        .font(Design.Typography.mono(0.9))
                                        .foregroundStyle(latest && agent.running ? Design.Retro.accent : Design.Ink.faint)
                                        .frame(width: 16, alignment: .trailing)
                                    Text(line)
                                        .font(Design.Typography.caption())
                                        .foregroundStyle(latest ? Design.Ink.primary : Design.Ink.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .id(i)
                            }
                        }
                    }
                    .padding(Design.Space.normal)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .strokeBorder(Design.Stroke.divider, lineWidth: Design.Stroke.hairline))
                .onChange(of: agent.log.count) { _ in
                    if let last = agent.log.indices.last {
                        withAnimation(Design.Motion.animation(Design.Motion.standard)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
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

/// A small, always-interactive STOP pill shown while a computer-use task runs.
/// The Computer Use card itself is made pure-display during a run (so it can't
/// swallow the agent's input), which also disables its own Stop button — so this
/// separate panel, kept OUT of the pass-through, is how you stop a run. Anchored
/// at the bottom-centre, away from where the agent usually clicks.
@MainActor
final class StopHUD {
    static let shared = StopHUD()
    static let windowID = NSUserInterfaceItemIdentifier("visor.cu.stop")
    private var panel: NSPanel?

    func show() {
        let p = panel ?? make()
        if let screen = NSScreen.main {
            let f = screen.frame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 42))
        }
        p.ignoresMouseEvents = false
        p.orderFrontRegardless()
        panel = p
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 132, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.identifier = Self.windowID
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: StopHUDView())
        panel = p
        return p
    }
}

private struct StopHUDView: View {
    @ObservedObject private var agent = ComputerUseAgent.shared

    var body: some View {
        Button(action: agent.stop) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 9, height: 9)
                Text("STOP")
                    .font(Design.Text.f(12)).tracking(2)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(Color.red.opacity(0.92)))
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
    }
}
