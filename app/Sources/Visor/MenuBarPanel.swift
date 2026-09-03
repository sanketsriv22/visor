import SwiftUI

/// The status-bar dropdown, as a designed panel rather than a system menu.
///
/// This is most people's first contact with Visor, and a stock `NSMenu` of
/// grey rows — several of them ("Send tasks to", "Run agents in", "Run in
/// folder") left over from before the HUD existed — was the worst possible
/// first impression. This is a small SwiftUI card in a popover: the few things
/// worth doing from the menu bar, with room to breathe.
struct MenuBarPanel: View {
    let version: String
    let computerUseOn: Bool
    let onOpenVisor: () -> Void
    let onComputerUse: () -> Void
    let onDictate: () -> Void
    let onSettings: () -> Void
    let onWhatsNew: () -> Void
    let onCheckUpdates: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header

            row("Open Visor", symbol: "rectangle.on.rectangle", hint: ShortcutSettings.hint(.toggle), action: onOpenVisor)
            row("Computer Use", symbol: "cursorarrow.rays",
                trailing: { stateDot(computerUseOn) }, action: onComputerUse)
            row("Dictate", symbol: "waveform", hint: ShortcutSettings.hint(.dictate), action: onDictate)

            Divider().padding(.vertical, 4)

            row("Settings…", symbol: "gearshape", hint: "⌘,", action: onSettings)
            row("What's New", symbol: "sparkles", action: onWhatsNew)
            row("Check for Updates…", symbol: "arrow.triangle.2.circlepath", action: onCheckUpdates)

            Divider().padding(.vertical, 4)

            row("Quit Visor", symbol: "power", hint: "⌘Q", action: onQuit)
        }
        .padding(8)
        .frame(width: 264)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            Text("Visor").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(version)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 8)
    }

    private func stateDot(_ on: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(on ? "On" : "Off")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(on ? .primary : .secondary)
        }
    }

    private func row(_ title: String, symbol: String, hint: String? = nil,
                     action: @escaping () -> Void) -> some View {
        row(title, symbol: symbol, trailing: {
            if let hint {
                Text(hint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }, action: action)
    }

    private func row<Trailing: View>(_ title: String, symbol: String,
                                     @ViewBuilder trailing: () -> Trailing,
                                     action: @escaping () -> Void) -> some View {
        MenuRow(title: title, symbol: symbol, trailing: trailing(), action: action)
    }
}

/// One row of the panel, with its own hover highlight — the feedback a system
/// menu gives for free and a custom one has to draw.
private struct MenuRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let trailing: Trailing
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Color.accentColor : .secondary)
                    .frame(width: 20)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
