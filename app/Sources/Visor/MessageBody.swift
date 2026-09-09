import AppKit
import MarkdownUI
import SwiftUI

/// The body of an assistant turn, rendered as real Markdown blocks.
///
/// Replies used to be shown as plain text while streaming and then parsed
/// with `AttributedString`'s inline-only Markdown once they settled, which
/// meant headings, lists, tables and code fences never became blocks — a
/// bulleted answer arrived as a wall of asterisks. This is the one renderer
/// both the notch card and the HUD draw replies with, so the two never drift.
///
/// It is a thin interface over MarkdownUI on purpose: `content` in, blocks
/// out. If the engine changes (MarkdownUI is in maintenance; its successor
/// needs macOS 15) nothing outside this file has to.
struct MessageBody: View {
    let content: String
    /// While tokens are arriving the text is re-parsed on a short throttle
    /// rather than on every token, which is the difference between a smooth
    /// stream and a stuttering one.
    var streaming = false
    /// 1.0 in the notch; the HUD raises it.
    var scale: Double = 1

    @StateObject private var throttle = StreamThrottle()

    var body: some View {
        // The code block style lives inside the theme rather than as a
        // separate modifier: `.markdownTheme` replaces the whole theme in the
        // environment, so a block style applied outside it was overwritten.
        Markdown(streaming ? throttle.displayed : content)
            .markdownTheme(.visor(scale: scale))
            .textSelection(.enabled)
            .onAppear { throttle.push(content, immediate: true) }
            .onChange(of: content) { new in throttle.push(new, immediate: !streaming) }
            .onChange(of: streaming) { live in if !live { throttle.push(content, immediate: true) } }
    }
}

/// Coalesces a burst of token updates into one re-render every ~80ms.
///
/// Tokens can arrive faster than a frame. Parsing Markdown for each one is
/// wasted work the eye can't see; parsing at a steady cadence keeps the
/// stream visibly alive without the layout thrashing under it. The last
/// value always lands: a pending commit reads `latest` when it fires.
final class StreamThrottle: ObservableObject {
    @Published private(set) var displayed = ""
    private var latest = ""
    private var scheduled = false
    private let interval: TimeInterval = 0.08

    func push(_ text: String, immediate: Bool) {
        latest = text
        if immediate {
            scheduled = false
            if displayed != text { displayed = text }
            return
        }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.scheduled else { return }
            self.scheduled = false
            if self.displayed != self.latest { self.displayed = self.latest }
        }
    }
}

/// A fenced code block: language tag, a copy control, and contained
/// horizontal scrolling so a long line widens the block's scroller rather
/// than the card.
struct VisorCodeBlock: View {
    let configuration: CodeBlockConfiguration
    let scale: Double
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text((configuration.language ?? "code").uppercased())
                    .font(.system(size: 9 * scale, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Design.Ink.tertiary)
                Spacer(minLength: 0)
                Button(action: copy) {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9 * scale, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 9 * scale, weight: .medium))
                    }
                    .foregroundStyle(copied ? Color.green.opacity(0.9) : Design.Ink.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.visor)
                .accessibilityIdentifier("visor.message.code.copy")
                .help("Copy this code block")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Rectangle().fill(Design.Surface.hairline).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.18))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(RoundedRectangle(cornerRadius: Design.Radius.pill, style: .continuous)
            .fill(Color.black.opacity(0.38)))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.pill, style: .continuous)
            .stroke(Design.Surface.hairline, lineWidth: 1))
        .markdownMargin(top: 0, bottom: 10)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

extension MarkdownUI.Theme {
    /// Visor's reading typography for replies: the card's white-on-black ink,
    /// a quiet paragraph rhythm, headings that step up by size rather than
    /// shout, and tables that stay usable at notch width.
    static func visor(scale: Double) -> MarkdownUI.Theme {
        let base = 12 * scale
        return MarkdownUI.Theme()
            .text {
                ForegroundColor(Color.white.opacity(0.88))
                FontSize(base)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(Color.white.opacity(0.92))
                BackgroundColor(Color.white.opacity(0.1))
            }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(Color(red: 0.62, green: 0.72, blue: 1.0)) }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.3)) }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.15)) }
                    .markdownMargin(top: 10, bottom: 5)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold) }
                    .markdownMargin(top: 6, bottom: 3)
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .blockquote { configuration in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 2)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(Color.white.opacity(0.7)) }
                        .relativeLineSpacing(.em(0.22))
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 8)
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: .em(0.2))
            }
            .codeBlock { configuration in
                VisorCodeBlock(configuration: configuration, scale: scale)
            }
            .thematicBreak {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
                    .markdownMargin(top: 8, bottom: 8)
            }
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTableBorderStyle(.init(color: Color.white.opacity(0.14)))
                        .markdownTableBackgroundStyle(
                            .alternatingRows(Color.clear, Color.white.opacity(0.035),
                                             header: Color.white.opacity(0.07)))
                }
                .markdownMargin(top: 0, bottom: 10)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 { FontWeight(.semibold) }
                        FontSize(.em(0.95))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .relativeLineSpacing(.em(0.15))
            }
    }
}
