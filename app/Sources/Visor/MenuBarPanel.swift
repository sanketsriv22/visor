import SwiftUI

/// The status-bar dropdown, as a designed panel rather than a system menu — and
/// now in the vintage theme: white on near-black, a purple accent, one pixel
/// face, glyph icons. This is most people's first contact with Visor, so it
/// sets the tone the rest of the app keeps.
struct MenuBarPanel: View {
    let version: String
    let computerUseOn: Bool
    let onOpenVisor: () -> Void
    let onComputerUse: () -> Void
    let onDictate: () -> Void
    let onSettings: () -> Void
    let onWhatsNew: () -> Void
    let onIntroduction: () -> Void
    let onCheckUpdates: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header

            row("Open Visor", glyph: Glyph.open, hint: ShortcutSettings.hint(.toggle), action: onOpenVisor)
            row("Computer Use", glyph: Glyph.computer,
                trailing: { stateTag(computerUseOn) }, action: onComputerUse)
            row("Dictate", glyph: Glyph.dictate, hint: ShortcutSettings.hint(.dictate), action: onDictate)

            rule()

            row("Settings", glyph: Glyph.settings, hint: "⌘,", action: onSettings)
            row("What's New", glyph: Glyph.whatsNew, action: onWhatsNew)
            row("Introduction", glyph: Glyph.open, action: onIntroduction)
            row("Check for Updates", glyph: Glyph.update, action: onCheckUpdates)

            rule()

            row("Quit Visor", glyph: Glyph.quit, hint: "⌘Q", action: onQuit)
        }
        .padding(8)
        .frame(width: 268)
        .background(Design.Retro.bg)
        .tint(Design.Retro.accent)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            BeamMark().frame(width: 15, height: 13)
            Text("VISOR")
                .font(.custom(Design.Text.face, size: 13)).tracking(3)
                .foregroundStyle(Design.Retro.text)
            Spacer()
            Text("v\(version)")
                .font(Design.Text.caption2)
                .foregroundStyle(Design.Retro.faint)
        }
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 8)
    }

    private func rule() -> some View {
        Rectangle().fill(Design.Retro.line).frame(height: 1).padding(.vertical, 4)
    }

    private func stateTag(_ on: Bool) -> some View {
        Text(on ? "ON" : "OFF")
            .font(Design.Text.f(9)).tracking(1)
            .foregroundStyle(on ? Design.Retro.accent : Design.Retro.faint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Design.Retro.radius)
                .fill(on ? Design.Retro.accentDim : Color.white.opacity(0.05)))
    }

    private func row(_ title: String, glyph: String, hint: String? = nil,
                     action: @escaping () -> Void) -> some View {
        row(title, glyph: glyph, trailing: {
            if let hint {
                Text(hint).font(Design.Text.caption2).foregroundStyle(Design.Retro.faint)
            }
        }, action: action)
    }

    private func row<Trailing: View>(_ title: String, glyph: String,
                                     @ViewBuilder trailing: () -> Trailing,
                                     action: @escaping () -> Void) -> some View {
        MenuRow(title: title, glyph: glyph, trailing: trailing(), action: action)
    }
}

/// One row, with its own hover highlight — the feedback a system menu gives for
/// free and a custom one has to draw. A purple wash and a left cursor bar.
private struct MenuRow<Trailing: View>: View {
    let title: String
    let glyph: String
    let trailing: Trailing
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Rectangle()
                    .fill(hovering ? Design.Retro.accent : Color.clear)
                    .frame(width: 2, height: 14)
                RetroIcon(glyph, size: 12, color: hovering ? Design.Retro.accent : Design.Retro.dim)
                    .frame(width: 16)
                Text(title).font(Design.Text.rowTitle).foregroundStyle(Design.Retro.text)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.trailing, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                .fill(hovering ? Design.Retro.accentDim : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
