import SwiftUI
import AppKit

struct StickyRootView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var ui: UIState
    @ObservedObject var ai: AIRunner
    var onToggle: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if ui.expanded {
                // The card extends up behind the notch (topInset) so the notch
                // overlaps its top edge — the note looks like it slides out
                // from *behind* the notch, not off its bottom lip.
                StickyCard(store: store, ai: ai, topInset: ui.notchSize.height, notchWidth: ui.notchSize.width, suppressHover: ui.settling, onClose: onToggle)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                NotchStrip(size: ui.notchSize, expanded: false, suppressHover: ui.settling)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Hit target over the notch (clicks are handled by the controller's
/// mouse-down monitor, not gestures). On hover while collapsed, the notch
/// appears to grow downward slightly — drawn in the underhang band below
/// the physical notch, since pixels inside the notch rect don't exist.
private struct NotchStrip: View {
    let size: CGSize
    let expanded: Bool
    /// True briefly after the card collapses, while the window is still resizing
    /// — suppresses the hover popup so it doesn't reflow mid-resize.
    var suppressHover: Bool

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if hovering && !expanded && !suppressHover {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 8,
                    bottomTrailingRadius: 8,
                    topTrailingRadius: 0
                )
                .fill(Color.black)
                Capsule()
                    .fill(.white.opacity(0.5))
                    .frame(width: size.width * 0.4, height: 2.5)
                    .padding(.bottom, 3)
            } else {
                Color.black.opacity(0.011) // effectively invisible, still hit-testable
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        // Gentle fade so the pull-tab eases in rather than snapping.
        .onHover { h in withAnimation(.easeInOut(duration: 0.2)) { hovering = h } }
    }
}

/// The card's outline minus the top edge — traces left, bottom (rounded), and
/// right. Used for the card border so the top (which sits at the black screen
/// edge) isn't stroked.
private struct CardEdgeBorder: Shape {
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

    static let font = NSFont.systemFont(ofSize: 13)
    static let maxLines = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
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

        func textDidBeginEditing(_ n: Notification) { parent.onFocus() }

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
    var onClose: () -> Void

    // @FocusState owns the SwiftUI text fields (title + add row). Task rows are
    // NSTextView-backed and can't be owned by @FocusState, so their focus is a
    // plain state (which retains any id), coordinated with `focused` below.
    @FocusState private var focused: UUID?
    @State private var focusedRow: UUID?
    @State private var pendingCaret: CaretLanding?  // column to preserve on ↑/↓ jumps
    @State private var newTask = ""
    @State private var hostWindow: NSWindow?
    @State private var beamHover = false
    private let addFieldID = UUID()
    private let titleFieldID = UUID()

    // Live drag-to-reorder state. dragOffset is the dragged row's offset from
    // its *current* slot (kept small via neighbor swaps); lastDY tracks the
    // gesture's cumulative translation so we add only the per-frame delta.
    @State private var draggingID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var lastDY: CGFloat = 0
    private let rowHeight: CGFloat = 23
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

                // Beam: send this note to a friend (AirDrop / Messages / Mail).
                Button(action: beamActiveNote) {
                    BeamGlyph(spectrum: beamHover)
                        .frame(width: 22, height: 19)
                        .foregroundStyle(beamHover ? Color.white : Color.secondary)
                        .scaleEffect(beamHover ? 1.1 : 1)
                        .padding(.vertical, 6)
                        .padding(.leading, 6)
                        // The glyph is thin strokes on a clear background; without
                        // this only the drawn pixels would be clickable, so clicks
                        // landing in the gaps would miss. Make the whole area hit.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(.easeInOut(duration: 0.18)) { beamHover = h } }
                .help("Beam a live link — edits sync both ways")
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)

            taskList

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(width: NotchController.cardWidth, height: NotchController.cardHeight + topInset)
        .background(
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        )
        .overlay(
            // Border on the left, bottom, and right only — no top edge, which sat
            // at the black screen edge and read as an odd light line.
            CardEdgeBorder(radius: 18).stroke(.white.opacity(0.14), lineWidth: 1)
        )
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

    /// The strip at notch height: VISOR in the left shoulder; the open-count tucked
    /// up against the right edge of the notch with the shared beacon beside it, in
    /// the right shoulder. A gap in the middle clears the physical notch.
    private var notchBand: some View {
        let gap = notchWidth + 18 // notch + a little clearance on each side
        let shoulder = max(0, (NotchController.cardWidth - gap) / 2)
        return HStack(spacing: 0) {
            Text("VISOR")
                .font(.system(size: 11, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
                .frame(width: shoulder, alignment: .leading)
            Spacer(minLength: 0).frame(width: gap)
            HStack(spacing: 0) {
                Text("\(store.openTaskCount) open")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.openTaskCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                if store.isActiveNoteShared { sharedBeacon } // right-aligned under the prism
            }
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .frame(width: shoulder, alignment: .leading)
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

    private var taskList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach($store.items) { $item in
                    NoteRow(
                        item: $item,
                        isFocused: focusedRow == item.id,
                        onFocus: { focusedRow = item.id; focused = nil },
                        suppressHover: suppressHover,
                        isSending: ai.isRunning(item.id),
                        isDragging: draggingID == item.id,
                        onToggle: { store.cycle(item.id) },
                        onComplete: { store.toggleDone(item.id) },
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
                        }
                    )
                    // The dragged row lifts and tracks the cursor with NO
                    // animation (its slot jumps are cancelled by dragOffset);
                    // every other row springs to its new slot.
                    .scaleEffect(draggingID == item.id ? 1.03 : 1, anchor: .leading)
                    .shadow(color: .black.opacity(draggingID == item.id ? 0.5 : 0),
                            radius: draggingID == item.id ? 10 : 0, y: 4)
                    .offset(y: draggingID == item.id ? dragOffset : 0)
                    .zIndex(draggingID == item.id ? 1 : 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(draggingID == item.id ? nil : reorderSpring, value: store.items.map(\.id))
                    .id(item.id)
                }
                addRow(proxy).id(addFieldID)
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
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
        // Swap into a neighbor slot once the row has dragged past its midpoint.
        // The slot change is instant; reducing dragOffset by a row keeps the
        // dragged row visually continuous under the cursor.
        while let idx = store.items.firstIndex(where: { $0.id == id }) {
            if dragOffset > rowHeight / 2, idx < store.items.count - 1 {
                store.items.swapAt(idx, idx + 1)
                dragOffset -= rowHeight
            } else if dragOffset < -rowHeight / 2, idx > 0 {
                store.items.swapAt(idx, idx - 1)
                dragOffset += rowHeight
            } else {
                break
            }
        }
    }

    private func dragEnded() {
        withAnimation(reorderSpring) {
            draggingID = nil
            dragOffset = 0
        }
        lastDY = 0
    }

    private func addRow(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("Add a task…", text: $newTask)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused, equals: addFieldID)
                .onSubmit { commitNewTask(proxy) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { focused = addFieldID }
    }

    private func commitNewTask(_ proxy: ScrollViewProxy) {
        let trimmed = newTask.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let id = withAnimation(reorderSpring) { store.addTask(trimmed) }
        newTask = ""
        focused = addFieldID // stay in the add field for rapid entry
        scrollTo(id, proxy) // keep the freshly added task (and add field) in view
    }

    private func focusRow(_ id: UUID) {
        DispatchQueue.main.async { focused = nil; focusedRow = id }
    }

    /// Scroll the task list so `id` is visible (used when a new task is added past
    /// the current bottom of the viewport).
    private func scrollTo(_ id: UUID, _ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
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

    private var sendHint: String {
        if ai.defaultProvider?.isDevinCloud == true {
            return "hover a task → ✈ starts a \(ai.defaultProviderName) session"
        }
        return ai.runMode == .terminal
            ? "hover a task → ✈ opens it in \(ai.defaultProviderName) (Terminal)"
            : "hover a task → ✈ sends it to \(ai.defaultProviderName)"
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
                Text(sendHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            case .done:
                Button(action: ai.revealLog) {
                    Label(ai.lastSessionURL != nil
                          ? "\(ai.lastProviderName) session created — open in Devin"
                          : "\(ai.lastProviderName) finished — view log",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            case .failed(let why):
                Button(action: ai.revealLog) {
                    Label("\(ai.lastProviderName) failed (\(why))", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
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
    var otherNotes: [String]
    var onMove: (String) -> Void
    var onMoveToNew: () -> Void
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var landing: CaretLanding?
    var onLandingConsumed: () -> Void
    var onMoveUp: (CGFloat) -> Void
    var onMoveDown: (CGFloat) -> Void

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
                onMoveDown: onMoveDown
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
                        .buttonStyle(.plain)
                        .help("Send just this task to the chosen agent")
                    }
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete task")
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

/// A "beam" mark — a single ray entering a prism and dispersing out the far
/// side. Monochrome at rest; the output rays light up as a spectrum when
/// `spectrum` is true (the parent passes its hover state).
private struct BeamGlyph: View {
    var spectrum: Bool

    private var outputColors: [Color] {
        spectrum
            ? [Color(red: 0.89, green: 0.29, blue: 0.29),   // red
               Color(red: 0.94, green: 0.62, blue: 0.15),   // amber
               Color(red: 0.40, green: 0.66, blue: 0.92)]   // blue
            : [.secondary, .secondary, .secondary]
    }

    var body: some View {
        ZStack {
            // Incoming ray + prism — take the parent's foregroundStyle.
            Path { p in
                p.move(to: CGPoint(x: 0, y: 10)); p.addLine(to: CGPoint(x: 7, y: 10))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            Path { p in
                p.move(to: CGPoint(x: 11, y: 2.5))
                p.addLine(to: CGPoint(x: 5.5, y: 16.5))
                p.addLine(to: CGPoint(x: 16.5, y: 16.5))
                p.closeSubpath()
            }
            .stroke(style: StrokeStyle(lineWidth: 1.7, lineJoin: .round))
            // Dispersed output rays, fanning from the prism's far face.
            ray(to: CGPoint(x: 21, y: 6), outputColors[0])
            ray(to: CGPoint(x: 21.5, y: 10), outputColors[1])
            ray(to: CGPoint(x: 21, y: 14), outputColors[2])
        }
        .frame(width: 22, height: 19)
    }

    private func ray(to end: CGPoint, _ color: Color) -> some View {
        Path { p in p.move(to: CGPoint(x: 13.5, y: 10)); p.addLine(to: end) }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
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
