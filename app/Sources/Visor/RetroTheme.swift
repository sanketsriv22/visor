import AppKit
import SwiftUI

/// The vintage-computing theme: white on near-black, a dark-purple accent, one
/// pixel typeface, and glyph icons instead of SF Symbols. Every surface draws
/// from here so the whole app reads as one machine rather than a stack of views
/// that each picked their own greys.
extension Design {
    enum Retro {
        /// Near-black, faintly blue like an unlit CRT.
        static let bg = Color(red: 0.045, green: 0.045, blue: 0.062)
        /// A panel sitting just proud of the background.
        static let panel = Color(red: 0.09, green: 0.088, blue: 0.11)
        static let panelDeep = Color(red: 0.065, green: 0.063, blue: 0.083)
        static let line = Color.white.opacity(0.10)

        /// Monochrome by default — black and white — with the accent as bright
        /// white. An Appearance preset can swap this for a colour (dark purple,
        /// etc.) later; the whole app reads the accent from here, so one change
        /// re-tints everything.
        static let accent = Color.white.opacity(0.95)
        static let accentDim = Color.white.opacity(0.13)
        static let accentDeep = Color.white.opacity(0.35)

        static let text = Color.white.opacity(0.92)
        static let dim = Color.white.opacity(0.55)
        static let faint = Color.white.opacity(0.32)

        /// Sharp corners for the terminal look — a couple of pixels, not soft.
        static let radius: CGFloat = 3
    }
}

/// Extends the Departure Mono type scale (defined in SettingsKit) with the
/// sizes the semantic SwiftUI fonts used to cover, so a sweep can replace
/// `.caption`/`.headline`/etc. and keep everything on the one face.
extension Design.Text {
    static let caption2 = Font.custom(face, size: 9.5)
    static let callout = Font.custom(face, size: 12.5)
    static let headline = Font.custom(face, size: 13)
    static let title = Font.custom(face, size: 16)
    static let big = Font.custom(face, size: 22)
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
