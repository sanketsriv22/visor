import SwiftUI

/// The conversation, scrolled — one view for the notch card and the HUD.
///
/// Each surface used to keep its own transcript, and both jumped to the bottom
/// whenever the last message changed. While a reply streams that is every few
/// milliseconds, so scrolling up to re-read something was impossible: the
/// list snapped back under the cursor on the next token.
///
/// The rule now is the one every good chat client uses: follow the reply only
/// while you are already near the bottom. Scroll up and the transcript holds
/// still; a pill appears offering the way back down, and it also says that
/// something new arrived while you were reading.
///
/// Reading position survives a surface change. The notch card and the HUD
/// are separate windows with separate scroll views, so the position is kept
/// on the shared `ChatController` — whichever surface appears next scrolls
/// to the same message rather than starting over at the bottom.
struct TranscriptView<Empty: View>: View {
    @ObservedObject var chat: ChatController
    var layout: ChatSurface
    /// Becomes true when this surface is the one on screen; the transcript
    /// restores its reading position on that edge. The HUD is mounted
    /// permanently, so `onAppear` alone would only ever fire once.
    var active: Bool = true
    @ViewBuilder var empty: () -> Empty

    /// True while the view is pinned to the newest content.
    @State private var following = true
    /// Set when content arrived while the reader was scrolled up.
    @State private var unread = false
    /// Distance from the bottom of the content to the bottom of the viewport,
    /// as reported by the sentinel. Infinite when the sentinel is off-screen.
    @State private var bottomDistance: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// How tall the content was last time, to tell growth from scrolling.
    @State private var contentHeight: CGFloat = 0

    /// Within this many points of the end counts as "at the bottom": far
    /// enough that the tail of a growing reply doesn't unpin you, close
    /// enough that a deliberate scroll up does.
    private static var followThreshold: CGFloat { 48 }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                GeometryReader { outer in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: layout.rowSpacing) {
                            if chat.conversation.messages.isEmpty {
                                empty()
                            }
                            ForEach(chat.conversation.messages) { message in
                                MessageRow(message: message,
                                           isStreaming: chat.isStreaming
                                               && message.id == chat.conversation.messages.last?.id)
                                    .id(message.id)
                                    .background(RowMarker(id: message.id))
                            }
                            if let pending = chat.pendingApproval {
                                ToolApprovalRow(pending: pending,
                                                allow: { chat.approvePending(always: false) },
                                                allowAlways: { chat.approvePending(always: true) },
                                                deny: chat.denyPending)
                                    .id("approval")
                            }
                            if let error = chat.error {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: layout.errorSize))
                                    .foregroundStyle(.orange)
                                    .padding(.top, 2)
                                    .accessibilityIdentifier("visor.transcript.error")
                                    .id("error")
                            }
                            // The anchor to scroll to, and the sentinel that
                            // measures how far the reader is from the end.
                            // Scrolling to the last message would stop short
                            // of the composer while the text is still growing.
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: BottomEdgeKey.self,
                                    value: BottomEdge(inViewport: g.frame(in: .named("visor.transcript")).maxY,
                                                      inContent: g.frame(in: .named("visor.content")).maxY))
                            }
                            .frame(height: 1)
                            .id("bottom")
                        }
                        .padding(.horizontal, layout.horizontalPadding)
                        .padding(.vertical, layout.verticalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: "visor.transcript")
                    .coordinateSpace(name: "visor.content")
                    .onAppear { viewportHeight = outer.size.height }
                    .onChange(of: outer.size.height) { viewportHeight = $0 }
                }
                .onPreferenceChange(BottomEdgeKey.self) { edge in
                    bottomDistance = edge.inViewport - viewportHeight
                    let grew = edge.inContent > contentHeight + 0.5
                    contentHeight = edge.inContent
                    let near = bottomDistance <= Self.followThreshold
                    // Content growing under a pinned reader — an approval
                    // card, a table, a reply's next paragraph — is not the
                    // reader scrolling away. Stay pinned and go to the end.
                    if following, grew, !near {
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                        return
                    }
                    if near != following {
                        following = near
                        chat.transcriptFollowing = near
                    }
                    if near { unread = false }
                }
                .onPreferenceChange(VisibleRowsKey.self) { rows in
                    // The topmost row whose top edge is on screen is where the
                    // reader is; the other surface opens there.
                    guard !following else { return }
                    let anchor = rows.filter { $0.value >= -4 }.min { $0.value < $1.value }?.key
                    if let anchor { chat.readingAnchor = anchor }
                }
                .onChange(of: chat.conversation.messages.last?.content) { _ in
                    if following {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        unread = true
                    }
                }
                .onChange(of: chat.conversation.messages.count) { _ in
                    // A new turn is always yours: sending pins you back to
                    // the end so the reply appears where you're looking.
                    if following || chat.conversation.messages.last?.role == .user {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        following = true
                        unread = false
                    } else {
                        unread = true
                    }
                }
                .onChange(of: chat.pendingApproval != nil) { pending in
                    if pending, following {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: chat.conversation.id) { _ in
                    // Opening a different chat starts at its end.
                    following = true
                    unread = false
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { restore(proxy) }
                .onChange(of: active) { on in if on { restore(proxy) } }

                if !following {
                    LatestPill(unread: unread, scale: layout.scale) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        following = true
                        unread = false
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: following)
            .accessibilityIdentifier("visor.transcript")
        }
    }

    /// Land where the reader left the other surface.
    private func restore(_ proxy: ScrollViewProxy) {
        // After layout, not during it: the lazy stack has nothing to scroll
        // to until the first pass has run.
        DispatchQueue.main.async {
            if chat.transcriptFollowing {
                following = true
                proxy.scrollTo("bottom", anchor: .bottom)
            } else if let anchor = chat.readingAnchor,
                      chat.conversation.messages.contains(where: { $0.id == anchor }) {
                following = false
                proxy.scrollTo(anchor, anchor: .top)
            } else {
                following = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

/// Which face the transcript and composer are drawn for. The two share every
/// behaviour and differ only in density.
enum ChatSurface {
    case compact, hud

    var scale: Double { self == .compact ? 1 : 1.15 }
    var rowSpacing: CGFloat { self == .compact ? 12 : 14 }
    var horizontalPadding: CGFloat { self == .compact ? 14 : 18 }
    var verticalPadding: CGFloat { self == .compact ? 12 : 14 }
    var errorSize: CGFloat { self == .compact ? 10 : 11 }
}

/// "↓ Latest": the way back to the end once the transcript has stopped
/// following, with a dot when there is something new down there.
private struct LatestPill: View {
    let unread: Bool
    let scale: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if unread {
                    Circle().fill(Design.Retro.accent).frame(width: 5, height: 5)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 9 * scale, weight: .bold))
                Text(unread ? "New reply" : "Latest")
                    .font(.system(size: 10 * scale, weight: .medium))
            }
            .foregroundStyle(Design.Ink.primary)
            .padding(.horizontal, 10)
            .frame(height: 24 * scale)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.visorBare)
        .accessibilityIdentifier("visor.transcript.latest")
        .help("Jump to the newest message")
    }
}

/// Reports a row's top edge in the transcript's coordinate space, so the
/// topmost visible row can be recorded as the reading anchor.
private struct RowMarker: View {
    let id: UUID
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(
                key: VisibleRowsKey.self,
                value: [id: g.frame(in: .named("visor.transcript")).minY])
        }
    }
}

/// Where the end of the content is: in the viewport (how far the reader
/// is from it) and in the content (how tall the content is).
private struct BottomEdge: Equatable {
    var inViewport: CGFloat
    var inContent: CGFloat
}

private struct BottomEdgeKey: PreferenceKey {
    /// Off-screen (not instantiated by the lazy stack) reads as infinitely
    /// far away, which is the right answer: the reader is nowhere near it.
    static var defaultValue = BottomEdge(inViewport: .infinity, inContent: 0)
    static func reduce(value: inout BottomEdge, nextValue: () -> BottomEdge) {
        let next = nextValue()
        value = BottomEdge(inViewport: min(value.inViewport, next.inViewport),
                           inContent: max(value.inContent, next.inContent))
    }
}

private struct VisibleRowsKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
