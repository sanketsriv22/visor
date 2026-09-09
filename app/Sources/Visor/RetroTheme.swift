import AppKit
import SwiftUI

/// A selectable theme — picked in Settings → Appearance and applied everywhere
/// (Settings, the menu-bar panel, the HUD). Monochrome by default; the rest are
/// presets. The whole app reads its colours from `Design.Retro`, which forwards
/// to whichever theme is current, so one change re-skins the lot.
enum VisorTheme: String, CaseIterable, Identifiable {
    case mono, purple, phosphor, amber, paper

    var id: String { rawValue }

    static let key = "visor.theme"
    static var current: VisorTheme {
        VisorTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .mono
    }

    var name: String {
        switch self {
        case .mono:     return "Mono"
        case .purple:   return "Midnight Purple"
        case .phosphor: return "Phosphor"
        case .amber:    return "Amber"
        case .paper:    return "Paper"
        }
    }

    /// Light themes flip the system chrome (window, controls) to aqua.
    var isDark: Bool { self != .paper }

    var bg: Color {
        switch self {
        case .mono:     return Color(red: 0.045, green: 0.045, blue: 0.062)
        case .purple:   return Color(red: 0.045, green: 0.042, blue: 0.065)
        case .phosphor: return Color(red: 0.02, green: 0.035, blue: 0.02)
        case .amber:    return Color(red: 0.05, green: 0.035, blue: 0.02)
        case .paper:    return Color(red: 0.93, green: 0.92, blue: 0.90)
        }
    }
    var panel: Color {
        isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.04)
    }
    var panelDeep: Color {
        isDark ? Color.black.opacity(0.28) : Color.black.opacity(0.05)
    }
    var line: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.12) }

    var accent: Color {
        switch self {
        case .mono:     return Color.white.opacity(0.95)
        case .purple:   return Color(red: 0.58, green: 0.40, blue: 0.94)
        case .phosphor: return Color(red: 0.35, green: 0.95, blue: 0.45)
        case .amber:    return Color(red: 0.98, green: 0.70, blue: 0.25)
        case .paper:    return Color(red: 0.10, green: 0.10, blue: 0.12)
        }
    }

    var text: Color { isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.88) }
    /// Ink on a solid accent fill.
    var onAccent: Color {
        switch self {
        case .purple: return Color.white.opacity(0.96)
        case .paper:  return Color.white.opacity(0.94)
        default:      return Color.black.opacity(0.9)
        }
    }
    var dim: Color { isDark ? Color.white.opacity(0.55) : Color.black.opacity(0.55) }
    var faint: Color { isDark ? Color.white.opacity(0.32) : Color.black.opacity(0.35) }

    /// A pair of swatch colours for the Appearance picker.
    var swatch: (Color, Color) { (bg, accent) }
}

/// The app's UI typeface — any font family installed on the machine, chosen in
/// Settings → Appearance. Stored as a family name; the system font (San
/// Francisco) is the default, and the bundled Departure Mono pixel face is the
/// pinned alternative. `Design.Text.f(size)` reads this.
enum VisorFont {
    static let key = "visor.fontFamily"
    static let system = "System"
    /// The bundled pixel face — still used for pixel icons whatever UI font is chosen.
    static let pixelFamily = "Departure Mono"
    static let defaultFamily = system

    static var current: String { UserDefaults.standard.string(forKey: key) ?? defaultFamily }

    /// A font in the given family at a size — `System` maps to San Francisco.
    static func font(_ family: String, _ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        family == system ? .system(size: size, weight: weight) : .custom(family, size: size)
    }
    static func current(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(current, size, weight: weight)
    }
    /// Departure Mono is the app's monospaced face; anything else falls back to
    /// the system monospaced font for numeric readouts.
    static var currentIsMono: Bool { current == pixelFamily }

    /// Every installed font family, with System and the bundled Departure Mono
    /// pinned first, then the rest alphabetically — the dropdown's contents.
    static var available: [String] {
        let all = NSFontManager.shared.availableFontFamilies
        let rest = all.filter { $0 != pixelFamily && $0 != system }
            .sorted { $0.lowercased() < $1.lowercased() }
        return [system, pixelFamily] + rest
    }
}

/// The one place the app's colours come from — forwards to the current theme.
/// Views read these at render, so changing the theme re-skins on next render
/// (the Settings window updates live via its @AppStorage; the menu and HUD are
/// rebuilt on next open).
extension Design {
    enum Retro {
        static var theme: VisorTheme { VisorTheme.current }
        static var bg: Color { theme.bg }
        static var panel: Color { theme.panel }
        static var panelDeep: Color { theme.panelDeep }
        static var line: Color { theme.line }
        static var accent: Color { theme.accent }
        static var accentDim: Color { theme.accent.opacity(0.18) }
        static var accentDeep: Color { theme.accent.opacity(0.4) }
        /// Ink drawn on top of a solid accent fill: black on the light
        /// accents (Mono's white, Amber, Phosphor), white on the dark ones.
        static var onAccent: Color { theme.onAccent }
        static var text: Color { theme.text }
        static var dim: Color { theme.dim }
        static var faint: Color { theme.faint }
        /// Sharp corners for the terminal look — a couple of pixels, not soft.
        static let radius: CGFloat = 3
    }
}

/// Extends the Departure Mono type scale (defined in SettingsKit) with the
/// sizes the semantic SwiftUI fonts used to cover, so a sweep can replace
/// `.caption`/`.headline`/etc. and keep everything on the one face.
extension Design.Text {
    static var caption2: Font { f(9.5) }
    static var callout: Font { f(12.5) }
    static var headline: Font { f(13) }
    static var title: Font { f(16) }
    static var big: Font { f(22, weight: .semibold) }
}

/// A pixel glyph used where an SF Symbol used to be. Rendered in Departure Mono
/// so it matches the text and needs no image asset; unknown glyphs fall back to
/// the system font for that character only.
struct RetroIcon: View {
    let glyph: String
    var size: CGFloat = 12
    var color: Color = Design.Retro.dim

    init(_ glyph: String, size: CGFloat = 12, color: Color = Design.Retro.dim) {
        self.glyph = glyph
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(glyph)
            .font(.custom(Design.Text.face, size: size))
            .foregroundStyle(color)
    }
}

/// The glyphs, named so callers don't sprinkle raw characters around. All drawn
/// from Departure Mono's geometric / block / arrow ranges.
enum Glyph {
    static let agents = "▚"
    static let voice = "◈"
    static let hud = "▣"
    static let computer = "▶"
    static let usage = "▤"
    static let workspace = "▦"
    static let mcp = "◇"
    static let memory = "◆"
    static let settings = "◎"
    static let whatsNew = "✦"
    static let update = "↻"
    static let quit = "⏻"
    static let open = "▢"
    static let search = "▷"
    static let check = "✓"
    static let star = "★"
    static let starOff = "☆"
    static let plus = "+"
    static let close = "×"
    static let chevron = "▾"
    static let bullet = "▪"
    static let dictate = "◍"
}

/// Visor's own mark — the bundled trefoil, tinted. Used wherever the app needs
/// to sign itself (the Settings sidebar, the menu-bar panel) instead of a stock
/// SF Symbol standing in for it.
struct BeamMark: View {
    var color: Color = Design.Retro.accent
    private static let image: NSImage? = {
        guard let img = NSImage(named: "trefoilTemplate") else { return nil }
        img.isTemplate = true
        return img
    }()
    var body: some View {
        Group {
            if let img = Self.image {
                Image(nsImage: img).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
            } else {
                Text("◈").font(.custom(Design.Text.face, size: 13))
            }
        }
        .foregroundStyle(color)
    }
}

/// A single slider with two thumbs, for a range — SwiftUI ships only the
/// one-thumb kind. Values are normalised 0…1; the caller maps them to whatever
/// scale it likes. Used for the chess response-time band, which was two
/// separate sliders for one idea.
struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    var accent: Color = Design.Retro.accent

    private let thumb: CGFloat = 14
    private let trackH: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.width - thumb)
            let xLow = CGFloat(min(low, high)) * travel
            let xHigh = CGFloat(max(low, high)) * travel
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: trackH)
                Capsule().fill(accent)
                    .frame(width: xHigh - xLow, height: trackH)
                    .offset(x: xLow + thumb / 2)
                thumbView.offset(x: xLow).gesture(drag(travel: travel, setting: $low, other: high))
                thumbView.offset(x: xHigh).gesture(drag(travel: travel, setting: $high, other: low))
            }
            .frame(height: thumb)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 18)
    }

    private var thumbView: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Design.Retro.text)
            .frame(width: thumb, height: thumb)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }

    private func drag(travel: CGFloat, setting: Binding<Double>, other: Double) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { g in
            let v = min(1, max(0, Double((g.location.x - thumb / 2) / travel)))
            setting.wrappedValue = v
        }
    }
}

/// A segmented pixel bar you drag to set a value — an arcade power meter rather
/// than a hairline slider. Reads 0…1; the caller maps it. Used for engine
/// strength, where a plain slider felt like a form field, not a game.
struct PixelGauge: View {
    @Binding var value: Double
    var segments: Int = 22
    var enabled: Bool = true

    var body: some View {
        GeometryReader { geo in
            let filled = enabled ? Int((value * Double(segments)).rounded()) : 0
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(i < filled ? Design.Retro.accent : Color.white.opacity(0.09))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                value = min(1, max(0, Double(g.location.x / max(1, geo.size.width))))
            })
        }
        .frame(height: 16)
    }
}

/// A rectangular, hairlined panel — the theme's card. Sharp corners and a thin
/// line, the way a box is drawn in text.
struct RetroPanel<Content: View>: View {
    var fill: Color = Design.Retro.panel
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                .fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Design.Retro.radius, style: .continuous)
                .stroke(Design.Retro.line, lineWidth: 1))
    }
}
