import SwiftUI
import AppKit

struct StickyRootView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var ui: UIState
    @ObservedObject var ai: AIRunner
    @ObservedObject var chat: ChatController
    var onToggle: () -> Void
    var onMode: (VisorMode) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if ui.expanded {
                // The card extends up behind the notch (topInset) so the notch
                // overlaps its top edge — the note looks like it slides out
                // from *behind* the notch, not off its bottom lip.
                //
                // Both faces live in one ZStack and the window never resizes
                // between them, so switching modes is a pure SwiftUI
                // animation: the card grows sideways instead of the window
                // snapping to a new size under it.
                // Unconditional: it decides for itself whether to draw, so
                // starting dictation never invalidates this body and the card
                // beneath it is never rebuilt.
                //
                // Suppressed on the chat face, which already shows the mic
                // state and level in its own header — two indicators for one
                // thing, and this one lands on top of the card's controls.
                ListeningPillHost(voice: chat.voice,
                                  notch: ui.trueNotch,
                                  suppressed: ui.mode != .notes)
                    .zIndex(1)

                // Hidden while the HUD is up, and it *retracts* to get there —
                // scaling into the notch it came from rather than the window
                // being ordered away underneath it, which is what made the
                // switch feel like a cut rather than a movement.
                if !ui.mode.isFullScreen {
                    morphingCard
                        .transition(.scale(scale: 0.02, anchor: .top)
                            .combined(with: .opacity))
                }

                // One switcher, measured from the notch rather than the card.
                //
                // Two bugs met here. Each face used to build its own, so a
                // swap destroyed one instance and created another and SwiftUI
                // cross-faded them — the icons read as replaced rather than
                // switched. Hoisting to one instance fixed that, but it hung
                // off the card as an overlay, and the card's width animates
                // 420 → 530 during a swap. Its centre is stable only once the
                // layout settles; mid-flight the overlay is re-proposed the
                // card's intermediate width every frame, so the switcher
                // drifted for the length of the transition and landed back
                // where it started.
                //
                // Here it's a sibling of the card, positioned off the notch —
                // which cannot move while the notch is open — so there is no
                // animating geometry between it and the screen.
                if !ui.mode.isFullScreen {
                    ModeSwitcher(mode: ui.mode, onSelect: onMode)
                        .frame(height: ui.notchSize.height)
                        .offset(x: -switcherDistance)
                        // Out of the notch, with the card.
                        //
                        // Being a sibling rather than the card's overlay is
                        // what stops it drifting during a face swap, but it
                        // also meant it stopped inheriting the card's
                        // transition: on open the icons simply appeared, fully
                        // formed, while the card was still growing out of the
                        // notch behind them. The anchor is the notch's centre
                        // expressed in the switcher's own width, so it scales
                        // out of the same point the card does instead of
                        // swelling in place off to one side.
                        //
                        // Transitions only run on insert and remove, so this
                        // costs nothing during a swap — the view is never
                        // replaced there, which was the original point.
                        .transition(.scale(scale: 0.02, anchor: switcherAnchor)
                            .combined(with: .opacity))
                        .zIndex(3)
                }
            } else {
                // Collapsed. The strip sits over the physical notch; the
                // listening pill extends to its right, so the notch appears to
                // widen rather than a window opening beside it.
                // .top so the extension lines up with the notch's top edge;
                // the strip below it is 8pt taller than the hardware because of
                // the click underhang.
                HStack(alignment: .top, spacing: 0) {
                    if ui.listening {
                        // The mirror of the meter: same width, same shape,
                        // rounded on the outer corner instead of the inner one.
                        ListeningPill(voice: chat.voice,
                                      height: ui.trueNotch.height,
                                      side: .leading)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    NotchStrip(size: ui.notchSize)
                    if ui.listening {
                        ListeningPill(voice: chat.voice, height: ui.trueNotch.height)
                            // Symmetric: it retracts back under the notch the
                            // way it came out. A plain fade on removal is what
                            // made closing feel abrupt next to opening.
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: ui.listening)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// How far left of centre the switcher sits — clear of the notch, hugging
    /// its edge.
    private var switcherDistance: CGFloat {
        (ui.notchSize.width + NotchController.notchClearance) / 2 + ModeSwitcher.width / 2
    }

    /// That same point, as a UnitPoint in the switcher's coordinate space.
    ///
    /// UnitPoint is measured in multiples of the view's own size and is happy
    /// outside 0…1, so a point two and a half widths to the right of a 50pt
    /// control is expressible — and after the offset it lands exactly on the
    /// centre of the notch.
    private var switcherAnchor: UnitPoint {
        UnitPoint(x: 0.5 + switcherDistance / ModeSwitcher.width, y: 0)
    }

    private var cardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 18,
            topTrailingRadius: 0)
    }

    /// One card that changes shape, rather than two cards dissolving into each
    /// other.
    ///
    /// The chrome — fill, border, shadow — is a single persistent view whose
    /// frame animates between the two modes' sizes, so the black card visibly
    /// grows and shrinks along the spring. Only the *contents* swap, and they
    /// cross-fade quickly inside the moving shape.
    ///
    /// Previously each mode drew its own background at its own fixed size,
    /// which gave SwiftUI two unrelated views and no choice but to dissolve
    /// one into the other — that's the fade this replaces. Content is clipped
    /// to the shape so a view still laid out at the old width can't spill past
    /// the edge mid-morph.
    private var morphingCard: some View {
        let size = NotchController.cardSize(for: ui.mode)
        return ZStack(alignment: .top) {
            Group {
                switch ui.mode {
                case .notes:
                    StickyCard(store: store, ai: ai, topInset: ui.notchSize.height,
                               notchWidth: ui.notchSize.width,
                               suppressHover: ui.settling,
                               listening: ui.listening && ui.mode == .notes,
                               mode: ui.mode, onMode: onMode, onClose: onToggle)
                case .chat, .hud:
                    ChatCard(chat: chat, ai: ai, topInset: ui.notchSize.height,
                             notchWidth: ui.notchSize.width,
                             mode: ui.mode, onMode: onMode,
                             onHUD: { onMode(.hud) }, onClose: onToggle)
                }
            }
            // Short and eased: the shape's travel should read as the motion,
            // not the contents flickering.
            .transition(.opacity.animation(.easeInOut(duration: 0.16)))
        }
        .frame(width: size.width, height: size.height + ui.notchSize.height)
        .background(cardShape.fill(Color.black))
        .clipShape(cardShape)
        .overlay(CardEdgeBorder(radius: 18).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }
}

/// Hit target over the notch (clicks are handled by the controller's
/// mouse-down monitor, not gestures). On hover while collapsed, the notch
/// appears to grow downward slightly — drawn in the underhang band below
/// the physical notch, since pixels inside the notch rect don't exist.
private struct NotchStrip: View {
    let size: CGSize

    /// Nothing but a hit target now.
    ///
    /// The hover pull-tab that used to appear beneath the notch is gone: it
    /// existed to teach that the notch is clickable, and once you know that
    /// it's just something flickering under the cursor every time you reach
    /// for the menu bar.
    var body: some View {
        Color.black.opacity(0.011)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
    }
}

/// The card's outline minus the top edge — traces left, bottom (rounded), and
/// right. Used for the card border so the top (which sits at the black screen
/// edge) isn't stroked.
struct CardEdgeBorder: Shape {
    var radius: CGFloat = 18
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))                                  // top-left
        p.addLine(to: CGPoint(x: 0, y: rect.height - r))                 // left edge
        p.addQuadCurve(to: CGPoint(x: r, y: rect.height),
                       control: CGPoint(x: 0, y: rect.height))           // bottom-left corner
        p.addLine(to: CGPoint(x: rect.width - r, y: rect.height))        // bottom edge
        p.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height - r),
                       control: CGPoint(x: rect.width, y: rect.height))  // bottom-right corner
        p.addLine(to: CGPoint(x: rect.width, y: 0))                      // right edge
        return p
    }
}

/// An `NSTextView`-backed task editor. Unlike SwiftUI's `TextField` (an
/// `NSTextField`), `NSTextView` does **not** select-all when it gains focus, so
/// programmatic focus (arrow-key navigation) lands as a clean caret with no
/// flash. It wraps long text and grows up to `maxLines`, reporting its height so
/// the row sizes to fit. Return submits; ↑/↓ on the first/last line jump to the
/// neighbouring row, otherwise move the caret between wrapped lines.
/// Where a caret should land when arrow-navigating into a row: a target x (in
/// the row editor's local coordinates, which line up across rows) and whether to
/// land on the first line (arrowed down into this row) or last line (arrowed up).
struct CaretLanding {
    var x: CGFloat
    var fromTop: Bool
}

/// NSTextView that reports when it becomes first responder. We can't rely on
/// `textDidBeginEditing` for focus tracking — that only fires on the first edit,
/// not when the user merely clicks into the field, so clicking from an empty new
/// task into another one never registered the focus change (and the empty row
/// lingered). `becomeFirstResponder` fires on the click itself.
private final class FocusReportingTextView: NSTextView {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}

private struct TaskEditor: NSViewRepresentable {
    @Binding var text: String
    var isDone: Bool
    var isFocused: Bool
    @Binding var height: CGFloat
    /// When this row is about to be focused via ↑/↓, where to put the caret so it
    /// preserves the column instead of jumping to the end. Consumed once.
    var landing: CaretLanding?
    var onFocus: () -> Void
    var onSubmit: () -> Void
    var onLandingConsumed: () -> Void
    var onMoveUp: (CGFloat) -> Void
    var onMoveDown: (CGFloat) -> Void
    /// Backspace pressed in an empty row. Returns true if the parent handled it
    /// (e.g. deleted an empty note), in which case the editor swallows the key.
    var onDeleteBackwardWhenEmpty: () -> Bool

    static let font = NSFont.systemFont(ofSize: 13)
    static let maxLines = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = FocusReportingTextView()
        tv.onFocus = { [weak coordinator = context.coordinator] in
            // Defer so we never mutate SwiftUI state inside an AppKit responder
            // pass (focus can also be set programmatically during updateNSView).
            DispatchQueue.main.async { coordinator?.parent.onFocus() }
        }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Self.font
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.string = text
        context.coordinator.style(tv)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.parent = self
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        }
        context.coordinator.style(tv)
        if isFocused, tv.window != nil, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
            if let landing {
                context.coordinator.placeCaret(tv, atX: landing.x, fromTop: landing.fromTop)
                DispatchQueue.main.async { self.onLandingConsumed() }
            } else {
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
        context.coordinator.recomputeHeight(tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TaskEditor
        init(_ p: TaskEditor) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            recomputeHeight(tv)
        }

        // Focus is reported via FocusReportingTextView.becomeFirstResponder
        // (fires on click), not here — textDidBeginEditing only fires on first edit.

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.moveUp(_:)):
                if caretAtFirstLine(tv) { parent.onMoveUp(caretX(tv)); return true }
                return false
            case #selector(NSResponder.moveDown(_:)):
                if caretAtLastLine(tv) { parent.onMoveDown(caretX(tv)); return true }
                return false
            case #selector(NSResponder.deleteBackward(_:)):
                // Backspace in an already-empty row: let the parent delete the
                // note if the whole note is empty. Otherwise fall through.
                if tv.string.isEmpty, parent.onDeleteBackwardWhenEmpty() { return true }
                return false
            default:
                return false
            }
        }

        /// Plain text, with secondary colour + strikethrough when the task is done.
        func style(_ tv: NSTextView) {
            let color: NSColor = parent.isDone ? .secondaryLabelColor : .labelColor
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            tv.textStorage?.removeAttribute(.strikethroughStyle, range: full)
            tv.textStorage?.addAttribute(.foregroundColor, value: color, range: full)
            if parent.isDone {
                tv.textStorage?.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
            }
            tv.font = TaskEditor.font
            tv.insertionPointColor = .labelColor
            tv.typingAttributes = [.font: TaskEditor.font, .foregroundColor: color]
        }

        func recomputeHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = ceil(Self.lineHeight)
            let used = lm.usedRect(for: tc).height
            let h = min(max(used, line), line * CGFloat(TaskEditor.maxLines))
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async { self.parent.height = h }
            }
        }

        private static var lineHeight: CGFloat {
            TaskEditor.font.ascender - TaskEditor.font.descender + TaskEditor.font.leading
        }

        func caretAtFirstLine(_ tv: NSTextView) -> Bool {
            guard let lm = tv.layoutManager, lm.numberOfGlyphs > 0 else { return true }
            let g = min(tv.selectedRange().location, lm.numberOfGlyphs - 1)
            let cur = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let first = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            return cur.minY <= first.minY + 0.5
        }

        func caretAtLastLine(_ tv: NSTextView) -> Bool {
            guard let lm = tv.layoutManager, lm.numberOfGlyphs > 0 else { return true }
            let g = min(tv.selectedRange().location, lm.numberOfGlyphs - 1)
            let cur = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let last = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil)
            return cur.maxY >= last.maxY - 0.5
        }

        /// The caret's x in the view's local coordinates — captured before an
        /// arrow jump so the target row can land at the same column. Rows share
        /// the same left edge, so this x maps directly across them.
        func caretX(_ tv: NSTextView) -> CGFloat {
            let loc = tv.selectedRange().location
            let screen = tv.firstRect(forCharacterRange: NSRange(location: loc, length: 0), actualRange: nil)
            guard let window = tv.window, screen != .zero else { return 0 }
            let win = window.convertPoint(fromScreen: screen.origin)
            return tv.convert(win, from: nil).x
        }

        /// Place the caret at the character nearest `x` on this row's first (or
        /// last) line — column-preserving arrow navigation.
        func placeCaret(_ tv: NSTextView, atX x: CGFloat, fromTop: Bool) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer, lm.numberOfGlyphs > 0 else {
                tv.setSelectedRange(NSRange(location: 0, length: 0)); return
            }
            lm.ensureLayout(for: tc)
            let g = fromTop ? 0 : lm.numberOfGlyphs - 1
            let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let point = NSPoint(x: x, y: line.midY + tv.textContainerOrigin.y)
            let idx = tv.characterIndexForInsertion(at: point)
            tv.setSelectedRange(NSRange(location: idx, length: 0))
        }
    }
}

private struct StickyCard: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var ai: AIRunner
    /// Height of the notch the card tucks up behind; content starts below it.
    var topInset: CGFloat
    /// Width of the notch, so the top band can flank it instead of overlapping.
    var notchWidth: CGFloat
    /// Suppress per-row hover affordances while the card animates open.
    var suppressHover: Bool
    /// True while dictation is showing its extension beside the notch.
    var listening: Bool
    var mode: VisorMode
    var onMode: (VisorMode) -> Void
    var onClose: () -> Void

    // @FocusState owns the SwiftUI text fields (title + add row). Task rows are
    // NSTextView-backed and can't be owned by @FocusState, so their focus is a
    // plain state (which retains any id), coordinated with `focused` below.
    @FocusState private var focused: UUID?
    @State private var focusedRow: UUID?
    @State private var pendingCaret: CaretLanding?  // column to preserve on ↑/↓ jumps
    @State private var hostWindow: NSWindow?
    @State private var beamHover = false
    /// Set by the header's add-task button to ask the task list to scroll to a
    /// just-added row (the button is outside the list's ScrollViewReader).
    @State private var scrollRequest: UUID?
    private let titleFieldID = UUID()

    // Live drag-to-reorder state. dragOffset is the dragged row's offset from
    // its *current* slot (kept small via neighbor swaps); lastDY tracks the
    // gesture's cumulative translation so we add only the per-frame delta.
    @State private var draggingID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var lastDY: CGFloat = 0
    // Measured per-row heights, so reordering works with multi-line tasks (rows
    // are not a fixed height). Keyed by item id; rowHeight is the fallback for a
    // row that hasn't been measured yet.
    @State private var rowHeights: [UUID: CGFloat] = [:]
    /// Whether the collapsible "completed" section at the bottom is expanded.
    @State private var showCompleted = false
    private let rowHeight: CGFloat = 23
    private let rowSpacing: CGFloat = 1   // matches the task VStack's spacing

    /// Slot-to-slot distance for the row `id`: its measured height plus the
    /// inter-row spacing, falling back to `rowHeight` before it's been measured.
    private func slotHeight(of id: UUID) -> CGFloat {
        rowHeights[id].map { $0 + rowSpacing } ?? rowHeight
    }
    // Quick, critically-damped: rows settle fast with no bouncy tail, so a new
    // drag can begin immediately after dropping (SwiftUI blocks new gestures
    // while the hierarchy is still animating).
    private var reorderSpring: Animation { .spring(response: 0.2, dampingFraction: 1.0) }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 18,
            topTrailingRadius: 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            notchBand

            HStack(spacing: 8) {
                Menu {
                    ForEach(store.noteNames, id: \.self) { name in
                        Button { store.switchTo(name) } label: {
                            if name == store.activeName {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                    Divider()
                    Button("New note", action: store.newNote)
                    Button {
                        withAnimation(reorderSpring) { store.sortByProgress() }
                    } label: {
                        Label("Clean up — sort by progress", systemImage: "arrow.up.arrow.down")
                    }
                    Button("Copy live link") { copyBeamLink() }
                    Button("Archive this note") { store.archiveCurrent() }
                    Button("Delete this note", role: .destructive) { confirmDeleteActiveNote() }
                    if !store.archivedNames.isEmpty {
                        Menu("Archived") {
                            ForEach(store.archivedNames, id: \.self) { name in
                                Button { store.restore(name) } label: {
                                    Label(name, systemImage: "tray.and.arrow.up")
                                }
                            }
                        }
                    }
                    Divider()
                    Menu("Sort by") {
                        ForEach(NotesStore.NoteSort.allCases, id: \.self) { mode in
                            Button { store.setNoteSort(mode) } label: {
                                if store.noteSort == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Switch or create notes")

                TextField("Name this note…", text: $store.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($focused, equals: titleFieldID)
                    .onSubmit { store.commitTitle() }

                // Add a task — drops an empty task at the bottom of the unfinished
                // group and focuses it. (The beam button moved up to the notch band.)
                addTaskButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)

            taskList

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        // Chrome and size are the root view's job now, so the card can morph
        // between modes as one shape.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowReader { hostWindow = $0 })
        .onExitCommand(perform: onClose)
        // Focusing a SwiftUI field (title/add row) means no task row is focused.
        .onChange(of: focused) { f in
            if f != nil {
                focusedRow = nil
                DispatchQueue.main.async { store.pruneEmptyTasks(except: nil) }
            }
        }
        // Moving to another row clears any blank row you left behind — but keeps
        // the row you just moved into. Deferred a tick so we don't mutate items
        // during the focus change (which crashes SwiftUI).
        .onChange(of: focusedRow) { row in
            DispatchQueue.main.async { store.pruneEmptyTasks(except: row) }
        }
    }

    /// The strip at notch height. Left shoulder: VISOR + the open-task count.
    /// Right shoulder: the share/presence beacon, then the beam button at the far
    /// right edge. A gap in the middle clears the physical notch.
    /// The strip at notch height, centred on the notch rather than stretched
    /// across the card. Both faces build this the same way and from the same
    /// constants, so nothing in it moves when the card changes size.
    private var notchBand: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            // Switcher against the notch, count pushed to the outer edge.
            //
            // The shoulder is a fixed width anchored to the notch, so whatever
            // sits at its *outer* end is a fixed distance from the notch and a
            // varying distance from the card edge — which left the switcher
            // stranded in open space on the wider chat card. Hugging the notch
            // puts it in the same place on both faces, whatever the card does.
            HStack(spacing: 4) {
                Text("\(store.openTaskCount) open")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.openTaskCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Reserved for the switcher the root draws.
                Color.clear.frame(width: ModeSwitcher.width, height: 1)
            }
            // Swapping the band left the count flush against the card's edge.
            .padding(.leading, 12)
            .frame(width: NotchController.shoulderWidth, alignment: .trailing)
            Spacer(minLength: 0)
                .frame(width: notchWidth + NotchController.notchClearance)
            // Parked at the shoulder's outer edge permanently. It used to hug
            // the notch and slide aside when dictation started, which kept it
            // clear of the extension but made a control jump for a reason
            // unrelated to it — a moving target is worse than a static one
            // slightly further out.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if store.isActiveNoteShared { sharedBeacon }
                beamButton
            }
            // Padding inside the fixed width, never outside it. Applied
            // after .frame this made the shoulder 116pt against the chat
            // card's 106 — and since the band is a centred assembly, ten extra
            // points on the right shifted everything left, so the mode
            // switcher moved when you swapped faces.
            .padding(.trailing, 10)
            .frame(width: NotchController.shoulderWidth, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .frame(height: topInset)
    }

    /// Indicates the active note is a live shared note, with a live viewer count.
    private var sharedBeacon: some View {
        HStack(spacing: 3) {
            Image(systemName: store.presenceCount > 1 ? "person.2.fill" : "dot.radiowaves.left.and.right")
            if store.presenceCount > 1 {
                Text("\(store.presenceCount)").font(.system(size: 10, weight: .semibold))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(store.presenceCount > 1 ? Color.green : Color.secondary)
        .help(store.presenceCount > 1
            ? "Shared note — \(store.presenceCount) people viewing now"
            : "Shared note — anyone with the link can edit")
    }

    /// Header button: drop an empty task at the bottom of the unfinished group and
    /// focus it to type into. (Sits where the beam button used to be.)
    private var addTaskButton: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            let id = withAnimation(reorderSpring) { store.addTask("") }
            focusRow(id)
            scrollRequest = id
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.leading, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.visor)
        .help("Add a task")
    }

    /// The trefoil "beam" button — share this note as a live link. Lives in the
    /// notch band's right shoulder, beside the share/presence beacon.
    private var beamButton: some View {
        Button(action: beamActiveNote) {
            BeamGlyph(spectrum: beamHover)
                .frame(width: 22, height: 19)
                .scaleEffect(beamHover ? 1.1 : 1)
                .frame(width: 22, height: 19)   // re-clamp so the hover pop doesn't resize the hit region
                // Hover only over the glyph; onContinuousHover's .ended fires
                // reliably on exit inside the non-activating panel.
                .onContinuousHover { phase in
                    let inside: Bool
                    switch phase {
                    case .active: inside = true
                    case .ended:  inside = false
                    }
                    withAnimation(.easeInOut(duration: 0.18)) { beamHover = inside }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.visor)
        .help("Beam a live link — edits sync both ways")
    }

    private var taskList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                // Unfinished tasks (and any plain lines) render here; completed
                // tasks collect in the collapsible section below. (The "add task"
                // button lives in the header now, not as a row.)
                ForEach($store.items) { $item in
                    if !(item.isTask && item.done) {
                        taskRow($item, proxy)
                    }
                }
                completedSection(proxy)
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .onPreferenceChange(RowHeightKey.self) { rowHeights = $0 }
        }
        // Hide the scroller — it looks heavy in the small notch panel, and
        // shows permanently under the "Show scroll bars: Always" system setting.
        // The list still scrolls (wheel/trackpad).
        .scrollIndicators(.hidden)
        // The header's add-task button can't reach this ScrollView's proxy, so it
        // posts the new row's id here and we scroll to it (deferred so the row is
        // built first).
        .onChange(of: scrollRequest) { req in
            guard let req else { return }
            scrollRequest = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(req, anchor: .bottom) }
            }
        }
        }
    }

    /// One configured task row with all of its drag / height-measure / animation
    /// modifiers. Shared by the unfinished list and the completed section.
    @ViewBuilder
    private func taskRow(_ binding: Binding<NoteItem>, _ proxy: ScrollViewProxy) -> some View {
        let item = binding.wrappedValue
        NoteRow(
            item: binding,
            isFocused: focusedRow == item.id,
            onFocus: { focusedRow = item.id; focused = nil },
            suppressHover: suppressHover,
            isSending: ai.isRunning(item.id),
            isDragging: draggingID == item.id,
            onToggle: { withAnimation(reorderSpring) { store.cycle(item.id) } },
            onComplete: { withAnimation(reorderSpring) { store.toggleDone(item.id) } },
            onSubmit: {
                let id = store.insertTask(after: item.id)
                focusRow(id)
                scrollTo(id, proxy)
            },
            onDelete: { withAnimation(reorderSpring) { store.remove(item.id) } },
            onSend: {
                let t = item.text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { ai.sendToDefault(tasks: [t], taskIDs: [item.id]) }
            },
            onOpenOrAddLink: { openOrAddLink(for: item.id) },
            onEditLink: { promptForLink(for: item.id) },
            onRemoveLink: { store.setLink(nil, for: item.id) },
            otherNotes: store.noteNames.filter { $0 != store.activeName },
            onMove: { name in
                withAnimation(reorderSpring) { store.moveTask(item.id, toNote: name) }
            },
            onMoveToNew: {
                withAnimation(reorderSpring) { store.moveTaskToNewNote(item.id) }
            },
            onDragChanged: { dy in dragChanged(item.id, dy) },
            onDragEnded: { dragEnded() },
            landing: pendingCaret,
            onLandingConsumed: { pendingCaret = nil },
            onMoveUp: { x in
                if let i = store.items.firstIndex(where: { $0.id == item.id }), i > 0 {
                    pendingCaret = CaretLanding(x: x, fromTop: false) // land on the row above's last line
                    focusedRow = store.items[i - 1].id
                }
            },
            onMoveDown: { x in
                if let i = store.items.firstIndex(where: { $0.id == item.id }), i < store.items.count - 1 {
                    pendingCaret = CaretLanding(x: x, fromTop: true) // land on the row below's first line
                    focusedRow = store.items[i + 1].id
                }
            },
            onDeleteBackwardWhenEmpty: { backspaceEmptyRow(item.id) }
        )
        // Measure each row's natural height (before the drag scale/offset) so
        // reordering can account for multi-line rows.
        .background(
            GeometryReader { g in
                Color.clear.preference(key: RowHeightKey.self, value: [item.id: g.size.height])
            }
        )
        // The dragged row lifts and tracks the cursor with NO animation (its slot
        // jumps are cancelled by dragOffset); every other row springs to its slot.
        .scaleEffect(draggingID == item.id ? 1.03 : 1, anchor: .leading)
        .shadow(color: .black.opacity(draggingID == item.id ? 0.5 : 0),
                radius: draggingID == item.id ? 10 : 0, y: 4)
        .offset(y: draggingID == item.id ? dragOffset : 0)
        .zIndex(draggingID == item.id ? 1 : 0)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(draggingID == item.id ? nil : reorderSpring, value: store.items.map(\.id))
        .id(item.id)
    }

    /// Completed tasks live in a collapsible section at the bottom, hidden by
    /// default behind a "N completed" toggle so finished work doesn't crowd the note.
    @ViewBuilder
    private func completedSection(_ proxy: ScrollViewProxy) -> some View {
        let completed = store.items.filter { $0.isTask && $0.done }
        if !completed.isEmpty {
            Button {
                withAnimation(reorderSpring) { showCompleted.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(completed.count) completed")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.visor)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if showCompleted {
                ForEach($store.items) { $item in
                    if item.isTask && item.done {
                        taskRow($item, proxy)
                    }
                }
            }
        }
    }

    private func dragChanged(_ id: UUID, _ dy: CGFloat) {
        if draggingID != id {
            draggingID = id
            lastDY = 0
            dragOffset = 0
        }
        dragOffset += dy - lastDY
        lastDY = dy
        // Swap into a neighbor slot once the row has dragged past that neighbor's
        // midpoint. Use the *neighbor's* measured height (rows vary — multi-line
        // tasks are taller), so the threshold and the dragOffset compensation
        // match the slot the row actually moved across. Using a fixed height here
        // made the dragged row (and its handle) drift off the cursor when passing
        // a multi-line task.
        while let idx = store.items.firstIndex(where: { $0.id == id }) {
            if idx < store.items.count - 1 {
                let h = slotHeight(of: store.items[idx + 1].id)
                if dragOffset > h / 2 {
                    store.items.swapAt(idx, idx + 1)
                    dragOffset -= h
                    continue
                }
            }
            if idx > 0 {
                let h = slotHeight(of: store.items[idx - 1].id)
                if dragOffset < -h / 2 {
                    store.items.swapAt(idx, idx - 1)
                    dragOffset += h
                    continue
                }
            }
            break
        }
    }

    private func dragEnded() {
        withAnimation(reorderSpring) {
            draggingID = nil
            dragOffset = 0
        }
        lastDY = 0
    }

    private func focusRow(_ id: UUID) {
        DispatchQueue.main.async { focused = nil; focusedRow = id }
    }

    /// Backspace in an empty row: remove that row and move the caret to the end
    /// of the previous one (joining up, like a text editor). If it's the only row
    /// and the note has no title either, delete the whole note. Returns true if it
    /// acted so the editor swallows the keystroke.
    private func backspaceEmptyRow(_ id: UUID) -> Bool {
        guard let idx = store.items.firstIndex(where: { $0.id == id }) else { return false }

        // The last empty thing in an otherwise-empty note → discard the note.
        let titleEmpty = store.title.trimmingCharacters(in: .whitespaces).isEmpty
        if store.items.count == 1 && titleEmpty {
            withAnimation(reorderSpring) { store.deleteNote(store.activeName) }
            return true
        }

        // Otherwise remove this empty row and focus a neighbour — the previous
        // row (caret at its end) if there is one, else the next row.
        let toPrev = idx > 0
        let neighbor = toPrev ? store.items[idx - 1].id : store.items[idx + 1].id
        withAnimation(reorderSpring) { store.remove(id) }
        if toPrev { pendingCaret = CaretLanding(x: 1_000_000, fromTop: false) } // end of the previous row
        focusedRow = neighbor
        return true
    }

    /// Scroll the task list so `id` is visible (used when a new task is added past
    /// the current bottom of the viewport). Deferred a beat so the freshly
    /// inserted row has been built and measured — scrolling in the same runloop
    /// tick can fire before the row exists, so nothing happens.
    private func scrollTo(_ id: UUID, _ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) }
        }
    }

    /// Beam this note as a *live* shared link: promote it to a shared note and
    /// open the macOS share sheet (AirDrop, Messages, Mail, Copy…) with the link.
    /// Opening it on another Mac joins the same note so edits sync both ways.
    /// Promoting touches the network, so the sheet appears once the link is ready.
    private func beamActiveNote() {
        guard let view = hostWindow?.contentView else { return }
        store.shareNote { link in
            guard let link, let url = URL(string: link) else { return }
            let picker = NSSharingServicePicker(items: [url])
            let b = view.bounds
            let anchor = NSRect(x: b.midX - 1, y: b.maxY - 56, width: 2, height: 2)
            NSApp.activate(ignoringOtherApps: true) // accessory app must activate to show the sheet
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    /// Promote this note to a live shared note and copy its link to the clipboard.
    /// Opening it on another Mac joins the same note so edits sync in real time.
    /// (Creating the share touches the network, so this is async; the link lands
    /// on the clipboard a moment later.)
    private func copyBeamLink() {
        store.shareNote { link in
            guard let link else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
    }

    /// Deleting a note is permanent (unlike Archive), so confirm first.
    private func confirmDeleteActiveNote() {
        let name = store.activeName
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = "This permanently deletes the note and its tasks. To keep it instead, use Archive."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true) // accessory app must activate for a modal
        // The note panel floats at .statusBar level, so a normal-level alert is
        // drawn behind it. Lift the alert just above the panel so it's visible.
        let panelLevel = hostWindow?.level ?? .statusBar
        alert.window.level = NSWindow.Level(rawValue: panelLevel.rawValue + 1)
        if alert.runModal() == .alertFirstButtonReturn {
            withAnimation(reorderSpring) { store.deleteNote(name) }
        }
    }

    /// Row link button behavior: if a task already has a link, open it in the
    /// default browser; otherwise prompt once to attach one.
    private func openOrAddLink(for id: UUID) {
        guard let idx = store.items.firstIndex(where: { $0.id == id }) else { return }
        if let raw = store.items[idx].link, let url = normalizedURL(raw) {
            NSWorkspace.shared.open(url)
        } else {
            promptForLink(for: id)
        }
    }

    private func promptForLink(for id: UUID) {
        guard let idx = store.items.firstIndex(where: { $0.id == id }) else { return }
        let current = store.items[idx].link ?? ""
        let alert = NSAlert()
        alert.messageText = current.isEmpty ? "Add link" : "Edit link"
        alert.informativeText = "Paste a URL for this task. Leave it blank and save to remove the link."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: current)
        field.placeholderString = "https://example.com"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let panelLevel = hostWindow?.level ?? .statusBar
        alert.window.level = NSWindow.Level(rawValue: panelLevel.rawValue + 1)
        if alert.runModal() == .alertFirstButtonReturn {
            store.setLink(field.stringValue, for: id)
        }
    }

    private func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }

    // Sending is per-task (the ✈ on each row), and runs are concurrent. The
    // footer shows how many are running, else the last run's result. Which
    // agent it goes to is set in the menu-bar settings.
    @ViewBuilder
    private var footer: some View {
        if ai.runningCount > 0 {
            Label(ai.runningCount == 1 ? "\(ai.lastProviderName) working…" : "\(ai.runningCount) agents working…",
                  systemImage: "circle.dotted")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else {
            switch ai.lastResult {
            case .none:
                EmptyView()
            case .done:
                Button(action: ai.revealLog) {
                    Label(ai.lastSessionURL != nil
                          ? "\(ai.lastProviderName) session created — open in Devin"
                          : "\(ai.lastProviderName) finished — view log",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.visorBare)
            case .failed(let why):
                Button(action: ai.revealLog) {
                    Label("\(ai.lastProviderName) failed (\(why))", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.visorBare)
            }
        }
    }
}

/// Hover affordance for the small row action icons (✈ send / ✕ delete): they
/// brighten and lift slightly on hover so it's clear they're clickable before
/// you click. onContinuousHover clears reliably on exit inside the panel.
private struct IconHoverGlow: ViewModifier {
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .brightness(over ? 0.3 : 0)
            .scaleEffect(over ? 1.18 : 1)
            .animation(.easeInOut(duration: 0.12), value: over)
            .onContinuousHover { phase in
                switch phase {
                case .active: over = true
                case .ended:  over = false
                }
            }
    }
}

/// A single editable line: a clickable checkbox + inline text for tasks, or
/// plain text otherwise. A delete affordance appears on hover.
private struct NoteRow: View {
    @Binding var item: NoteItem
    var isFocused: Bool
    var onFocus: () -> Void
    var suppressHover: Bool
    var isSending: Bool
    var isDragging: Bool
    var onToggle: () -> Void
    var onComplete: () -> Void
    var onSubmit: () -> Void
    var onDelete: () -> Void
    var onSend: () -> Void
    var onOpenOrAddLink: () -> Void
    var onEditLink: () -> Void
    var onRemoveLink: () -> Void
    var otherNotes: [String]
    var onMove: (String) -> Void
    var onMoveToNew: () -> Void
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var landing: CaretLanding?
    var onLandingConsumed: () -> Void
    var onMoveUp: (CGFloat) -> Void
    var onMoveDown: (CGFloat) -> Void
    var onDeleteBackwardWhenEmpty: () -> Bool

    @State private var hovering = false
    @State private var checkboxBump = false
    @State private var editorHeight: CGFloat = 17

    static func glyph(_ s: TaskStatus) -> String {
        switch s {
        case .open: return "circle"
        case .doing: return "circle.lefthalf.filled"
        case .blocked: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    static func tint(_ s: TaskStatus) -> AnyShapeStyle {
        switch s {
        case .open: return AnyShapeStyle(.secondary)
        case .doing: return AnyShapeStyle(.blue)
        case .blocked: return AnyShapeStyle(.red)
        case .done: return AnyShapeStyle(.green)
        }
    }

    static func label(_ s: TaskStatus) -> String {
        switch s {
        case .open: return "Open"
        case .doing: return "Doing"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }

    /// Quick scale "pop" when the checkbox is tapped or held.
    private func bump() {
        withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { checkboxBump = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { checkboxBump = false }
        }
    }

    var body: some View {
        // .center vertically aligns the handle, checkbox and text so they sit
        // on one line together.
        HStack(alignment: .center, spacing: 4) {
            // Drag handle — only this grabs for reordering, so dragging never
            // fights with editing the task text. A gesture-driven live reorder
            // (rows part as you drag) rather than a system drag-and-drop.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity((hovering || isDragging) && !suppressHover ? 0.95 : 0.45)
                // Invisible grab zone around the glyph so you can grab the general
                // area instead of pixel-aiming the three lines. Kept snug so the
                // handle and bullet sit close together on the left.
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .gesture(
                    // Global coordinate space: the row's own offset (it follows
                    // the cursor) must not feed back into the measured translation,
                    // or the drag glitches and tracks loosely.
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { onDragChanged($0.translation.height) }
                        .onEnded { _ in onDragEnded() }
                )

            if item.isTask {
                // Tap cycles open → doing → blocked → done; press-and-hold jumps
                // straight to done (or back to open) without clicking through.
                Image(systemName: Self.glyph(item.status))
                    .font(.system(size: 14))
                    .foregroundStyle(Self.tint(item.status))
                    .scaleEffect(checkboxBump ? 1.3 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: item.status)
                    .padding(3)
                    .contentShape(Rectangle())
                    .onTapGesture { bump(); onToggle() }
                    .onLongPressGesture(minimumDuration: 0.3) { bump(); onComplete() }
                    .help(Self.label(item.status) + " — tap to change, hold to complete")
            }

            // NSTextView-backed editor: wraps + grows like the old field, but
            // doesn't select-all on focus, so arrow-key navigation lands cleanly.
            TaskEditor(
                text: $item.text,
                isDone: item.isTask && item.done,
                isFocused: isFocused,
                height: $editorHeight,
                landing: isFocused ? landing : nil,
                onFocus: onFocus,
                onSubmit: onSubmit,
                onLandingConsumed: onLandingConsumed,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onDeleteBackwardWhenEmpty: onDeleteBackwardWhenEmpty
            )
            .frame(height: editorHeight)
        }
        // Float the actions over the row's trailing edge so they never push or
        // wrap the task text; a fade keeps them legible over any text under them.
        // NOTE: overlay must be applied BEFORE .onHover so the buttons are part
        // of the hovered subtree — otherwise moving onto a button flips hover
        // off (the button becomes the topmost view) and it vanishes mid-click.
        .overlay(alignment: .trailing) { trailingActions }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            if item.isTask {
                if item.link?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Button("Open link", action: onOpenOrAddLink)
                    Button("Edit link", action: onEditLink)
                    Button("Remove link", action: onRemoveLink)
                } else {
                    Button("Add link", action: onEditLink)
                }
                Divider()
            }
            Menu("Move to") {
                Button("New note") { onMoveToNew() }
                if !otherNotes.isEmpty {
                    Divider()
                    ForEach(otherNotes, id: \.self) { name in
                        Button(name) { onMove(name) }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        let showButtons = hovering && !suppressHover
        if isSending || showButtons {
            HStack(spacing: 6) {
                if item.isTask && isSending {
                    ProgressView().controlSize(.small).tint(.orange)
                        .frame(width: 22, height: 22)
                        .help("An agent is working on this task")
                }
                if showButtons {
                    if item.isTask && !item.done && !isSending {
                        Button(action: onSend) {
                            Image(systemName: "paperplane.fill").font(.system(size: 12)).foregroundStyle(.orange)
                                .frame(width: 24, height: 24)   // solid, reliable hit target
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.visor)
                        .modifier(IconHoverGlow())
                        .help("Send just this task to the chosen agent")
                    }
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.visor)
                    .modifier(IconHoverGlow())
                    .help("Delete task")
                    if item.isTask {
                        Button(action: onOpenOrAddLink) {
                            Image(systemName: item.link?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "link.circle.fill" : "link")
                                .font(.system(size: 13))
                                .foregroundStyle(item.link?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? Color.blue : Color.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.visor)
                        .modifier(IconHoverGlow())
                        .help(item.link?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "Open link" : "Add link")
                    }
                }
            }
            .padding(.leading, 28)
            .padding(.trailing, 2)
            .background(
                // Non-interactive fade so only the buttons capture clicks.
                LinearGradient(
                    stops: [.init(color: .black.opacity(0), location: 0),
                            .init(color: .black, location: 0.55)],
                    startPoint: .leading, endPoint: .trailing
                )
                .allowsHitTesting(false)
            )
            .transition(.opacity)
        }
    }
}

/// A "beam" mark — a 2-D trefoil knot, the simplest knot. Uses the crafted
/// `trefoilTemplate` template image when it's bundled (the packaged .app),
/// and falls back to a parametric trefoil drawn in code otherwise (e.g.
/// `swift run`, where Resources aren't bundled). Monochrome at rest (inherits
/// the parent's foregroundStyle); the strand lights up as a rainbow spectrum
/// when `spectrum` is true (the parent passes its hover state).
private struct BeamGlyph: View {
    var spectrum: Bool

    private static let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)

    /// The bundled template image, if present. Marked as a template so AppKit
    /// tints it from the alpha channel; SwiftUI then recolours via foregroundStyle.
    private static let templateImage: NSImage? = {
        guard let img = NSImage(named: "trefoilTemplate") else { return nil }
        img.isTemplate = true
        return img
    }()

    private var spectrumGradient: AngularGradient {
        AngularGradient(
            colors: [Color(red: 0.89, green: 0.29, blue: 0.29),   // red
                     Color(red: 0.94, green: 0.62, blue: 0.15),   // amber
                     Color(red: 0.40, green: 0.66, blue: 0.92),   // blue
                     Color(red: 0.89, green: 0.29, blue: 0.29)],  // back to red — seamless loop
            center: .center)
    }

    var body: some View {
        // SwiftUI can't interpolate between two different ShapeStyles (a solid
        // colour and a gradient), so toggling foregroundStyle snaps. Instead we
        // stack a grey base and the rainbow version and crossfade their opacity,
        // which *does* animate — giving a smooth grey↔lit transition on hover.
        ZStack {
            glyph(AnyShapeStyle(Color.secondary))
            glyph(AnyShapeStyle(spectrumGradient))
                .opacity(spectrum ? 1 : 0)
        }
        .frame(width: 22, height: 19)
        .animation(.easeInOut(duration: 0.18), value: spectrum)
    }

    /// One rendering of the trefoil tinted with `style`: the bundled template
    /// image when present, else the parametric vector fallback.
    @ViewBuilder private func glyph(_ style: AnyShapeStyle) -> some View {
        if let img = Self.templateImage {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(1.5)
                .foregroundStyle(style)
        } else {
            Self.trefoil(in: CGRect(x: 0, y: 0, width: 22, height: 19).insetBy(dx: 1.5, dy: 1.5))
                .stroke(style, style: Self.stroke)
        }
    }

    /// The standard 2-D trefoil:  x = sin t + 2 sin 2t,  y = cos t − 2 cos 2t.
    /// Sampled over one period and scaled to fit `rect` (centred on its box).
    private static func trefoil(in rect: CGRect) -> Path {
        let samples = 220
        let pts: [CGPoint] = (0...samples).map { i in
            let t = 2 * Double.pi * Double(i) / Double(samples)
            return CGPoint(x: sin(t) + 2 * sin(2 * t),
                           y: cos(t) - 2 * cos(2 * t))
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let scale = min(rect.width / (maxX - minX), rect.height / (maxY - minY))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2

        var path = Path()
        for (i, pt) in pts.enumerated() {
            let p = CGPoint(x: rect.midX + (pt.x - cx) * scale,
                            y: rect.midY + (pt.y - cy) * scale)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}

/// Collects each task row's measured height, keyed by item id, so drag-to-
/// reorder can handle rows of different heights (multi-line tasks).
private struct RowHeightKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Grabs the AppKit window hosting this SwiftUI view, so the share sheet
/// (NSSharingServicePicker) can be anchored to the note panel.
private struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// Root of the HUD's own window.
///
/// Separate from the card's root so neither window has to change size for the
/// other: the card's panel stays card-width and off the menu bar, and this one
/// is created at full screen and only ever shown or hidden.
struct HUDRootView: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var store: NotesStore
    @ObservedObject var ui: UIState
    var onExit: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // Always mounted, visibility driven by the mode — a view removed
            // from the hierarchy can't animate its own exit, which is why
            // leaving the HUD used to be instant.
            HUDView(chat: chat, store: store,
                    notchWidth: ui.notchSize.width,
                    topInset: ui.notchSize.height,
                    onExit: onExit,
                    onClose: onClose,
                    visible: ui.mode.isFullScreen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
