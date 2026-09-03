import SwiftUI

/// Pick the app's look — theme and font — applied everywhere the moment it's
/// chosen: Settings redraws live, the menu-bar panel and HUD pick it up the
/// next time they open.
struct AppearancePane: View {
    @AppStorage(VisorTheme.key) private var themeRaw = VisorTheme.mono.rawValue
    @AppStorage(VisorFont.key) private var fontRaw = VisorFont.departureMono.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Appearance",
                subtitle: "One look for the whole app — Settings, the menu-bar dropdown, and the HUD all follow it.")

            SettingsCard(label: "Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                    ForEach(VisorTheme.allCases) { theme in
                        swatch(theme)
                    }
                }
            }

            SettingsCard(label: "Font") {
                HStack(spacing: 8) {
                    ForEach(VisorFont.allCases) { fontChip($0) }
                    Spacer(minLength: 0)
                }
                Text("Departure Mono is the pixel face; System is San Francisco. Icons stay pixel either way.")
                    .font(Design.Text.caption2).foregroundStyle(Design.Retro.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func swatch(_ theme: VisorTheme) -> some View {
        let selected = themeRaw == theme.rawValue
        return Button { themeRaw = theme.rawValue } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                        .fill(theme.bg)
                        .frame(height: 48)
                    HStack(spacing: 5) {
                        Circle().fill(theme.accent).frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 1).fill(theme.text).frame(width: 34, height: 4)
                        RoundedRectangle(cornerRadius: 1).fill(theme.text.opacity(0.5)).frame(width: 20, height: 4)
                    }
                    .padding(9)
                }
                .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                    .stroke(selected ? Design.Retro.accent : Design.Retro.line,
                            lineWidth: selected ? 2 : 1))
                HStack(spacing: 5) {
                    RetroIcon(selected ? Glyph.check : "▸", size: 9,
                              color: selected ? Design.Retro.accent : Design.Retro.faint)
                    Text(theme.name).font(Design.Text.caption).foregroundStyle(Design.Retro.text)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func fontChip(_ f: VisorFont) -> some View {
        let selected = fontRaw == f.rawValue
        return Button { fontRaw = f.rawValue } label: {
            Text(f.name)
                .font(f.font(12))
                .foregroundStyle(selected ? Design.Retro.text : Design.Retro.dim)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                    .fill(selected ? Design.Retro.accentDim : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                    .stroke(selected ? Design.Retro.accent : Design.Retro.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
