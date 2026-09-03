import SwiftUI

/// Pick the app's look — theme and font. Changes are a draft: you try them in
/// the preview below and commit with Apply, rather than the whole app lurching
/// every time you tap a swatch.
struct AppearancePane: View {
    @AppStorage(VisorTheme.key) private var themeRaw = VisorTheme.mono.rawValue
    @AppStorage(VisorFont.key) private var fontRaw = VisorFont.departureMono.rawValue

    @State private var draftTheme: VisorTheme = .mono
    @State private var draftFont: VisorFont = .departureMono

    private var dirty: Bool {
        draftTheme.rawValue != themeRaw || draftFont.rawValue != fontRaw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Appearance",
                subtitle: "One look for the whole app — Settings, the menu-bar dropdown, and the HUD. Try it in the preview, then Apply.")

            SettingsCard(label: "Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                    ForEach(VisorTheme.allCases) { swatch($0) }
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

            SettingsCard(label: "Preview") {
                // Fixed height so the box doesn't jump as fonts/themes with
                // different metrics swap in.
                AppearancePreview(theme: draftTheme, font: draftFont)
                    .frame(height: 150)
            }

            HStack(spacing: 10) {
                Text(dirty ? "Unapplied changes" : "Up to date")
                    .font(Design.Text.caption2)
                    .foregroundStyle(dirty ? Design.Retro.accent : Design.Retro.faint)
                Spacer()
                if dirty {
                    Button("Revert") { syncDraft() }.controlSize(.small)
                }
                Button("Apply") {
                    themeRaw = draftTheme.rawValue
                    fontRaw = draftFont.rawValue
                }
                .controlSize(.small)
                .disabled(!dirty)
            }
        }
        .onAppear(perform: syncDraft)
    }

    private func syncDraft() {
        draftTheme = VisorTheme(rawValue: themeRaw) ?? .mono
        draftFont = VisorFont(rawValue: fontRaw) ?? .departureMono
    }

    private func swatch(_ theme: VisorTheme) -> some View {
        let selected = draftTheme == theme
        return Button { draftTheme = theme } label: {
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
        let selected = draftFont == f
        return Button { draftFont = f } label: {
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

/// A little mock of the app rendered in the *draft* theme and font, so you can
/// see the choice before committing it — its colours come straight from the
/// draft, not from `Design.Retro` (which is still the applied theme).
private struct AppearancePreview: View {
    let theme: VisorTheme
    let font: VisorFont

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("AGENTS").font(font.font(15)).foregroundStyle(theme.text)
                Text("▪▪▪").font(font.font(9)).foregroundStyle(theme.accent)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Circle().fill(theme.accent).frame(width: 8, height: 8)
                    Text("Default agent").font(font.font(12.5)).foregroundStyle(theme.text)
                    Spacer()
                    Text("gpt-5").font(font.font(11)).foregroundStyle(theme.dim)
                }
                Rectangle().fill(theme.line).frame(height: 1)
                HStack {
                    Text("Response time").font(font.font(11)).foregroundStyle(theme.dim)
                    Spacer()
                    Text("0.4s").font(font.font(11)).foregroundStyle(theme.accent)
                }
                Text("SET · Apply looks like this")
                    .font(font.font(10)).foregroundStyle(theme.faint)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous).fill(theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous).stroke(theme.line, lineWidth: 1))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous).fill(theme.bg))
        .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous).stroke(theme.line, lineWidth: 1))
    }
}
