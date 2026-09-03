import SwiftUI

/// Pick the app's look — theme and font. Changes are a draft: you try them in
/// the preview below and commit with Apply, rather than the whole app lurching
/// every time you tap a swatch.
struct AppearancePane: View {
    @AppStorage(VisorTheme.key) private var themeRaw = VisorTheme.mono.rawValue
    @AppStorage(VisorFont.key) private var fontRaw = VisorFont.defaultFamily

    @State private var draftTheme: VisorTheme = .mono
    @State private var draftFontFamily = VisorFont.defaultFamily

    private var dirty: Bool {
        draftTheme.rawValue != themeRaw || draftFontFamily != fontRaw
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
                fontDropdown
                Text("Any font installed on your Mac. Departure Mono ships with the app and is the default; icons stay pixel whatever you pick.")
                    .font(Design.Text.caption2).foregroundStyle(Design.Retro.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(label: "Preview") {
                AppearancePreview(theme: draftTheme, fontFamily: draftFontFamily)
                    .frame(height: 150)
            }

            HStack(spacing: 10) {
                Text(dirty ? "Unapplied changes" : "Up to date")
                    .font(Design.Text.caption2)
                    .foregroundStyle(dirty ? Design.Retro.accent : Design.Retro.faint)
                Spacer()
                if dirty { Button("Revert", action: syncDraft).controlSize(.small) }
                Button("Apply") {
                    themeRaw = draftTheme.rawValue
                    fontRaw = draftFontFamily
                }
                .controlSize(.small)
                .disabled(!dirty)
            }
        }
        .onAppear(perform: syncDraft)
    }

    private func syncDraft() {
        draftTheme = VisorTheme(rawValue: themeRaw) ?? .mono
        draftFontFamily = fontRaw
    }

    private func label(_ family: String) -> String {
        family == VisorFont.system ? "System" : family
    }

    private var fontDropdown: some View {
        Menu {
            ForEach(VisorFont.available, id: \.self) { family in
                Button { draftFontFamily = family } label: {
                    if draftFontFamily == family {
                        Label(label(family), systemImage: "checkmark")
                    } else {
                        Text(label(family))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label(draftFontFamily))
                    .font(VisorFont.font(draftFontFamily, 13))
                    .foregroundStyle(Design.Retro.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                RetroIcon(Glyph.chevron, size: 9, color: Design.Retro.dim)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                .fill(Design.Retro.panel))
            .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                .stroke(Design.Retro.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 300, alignment: .leading)
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
}

/// A little mock of the app rendered in the *draft* theme and font, so you can
/// see the choice before committing it — its colours and font come straight
/// from the draft, not from the applied theme.
private struct AppearancePreview: View {
    let theme: VisorTheme
    let fontFamily: String

    private func f(_ size: CGFloat) -> Font { VisorFont.font(fontFamily, size) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("AGENTS").font(f(15)).foregroundStyle(theme.text)
                Text("▪▪▪").font(f(9)).foregroundStyle(theme.accent)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Circle().fill(theme.accent).frame(width: 8, height: 8)
                    Text("Default agent").font(f(12.5)).foregroundStyle(theme.text)
                    Spacer()
                    Text("gpt-5").font(f(11)).foregroundStyle(theme.dim)
                }
                Rectangle().fill(theme.line).frame(height: 1)
                HStack {
                    Text("Response time").font(f(11)).foregroundStyle(theme.dim)
                    Spacer()
                    Text("0.4s").font(f(11)).foregroundStyle(theme.accent)
                }
                Text("SET · Apply looks like this").font(f(10)).foregroundStyle(theme.faint)
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
