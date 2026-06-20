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
                NotchStrip(size: ui.notchSize, expanded: false)
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

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if hovering && !expanded {
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
        .onHover { hovering = $0 }
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

    @FocusState private var focused: UUID?
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
                    Button("Copy beam link") { copyBeamLink() }
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
                .help("Beam this note to a friend")
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
            shape.strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .background(WindowReader { hostWindow = $0 })
        .onExitCommand(perform: onClose)
    }

    /// The strip at notch height: VISOR in the left shoulder, open-count in the
    /// right shoulder, with a gap in the middle cleared for the physical notch.
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
            Text("\(store.openTaskCount) open")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(store.openTaskCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(.trailing, 16)
                .frame(width: shoulder, alignment: .trailing)
        }
        .frame(height: topInset)
    }

    private var taskList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach($store.items) { $item in
                    NoteRow(
                        item: $item,
                        focused: $focused,
                        suppressHover: suppressHover,
                        isSending: ai.isRunning(item.id),
                        isDragging: draggingID == item.id,
                        onToggle: { store.cycle(item.id) },
                        onComplete: { store.toggleDone(item.id) },
                        onSubmit: { focusRow(store.insertTask(after: item.id)) },
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
                        onDragEnded: { dragEnded() }
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
                }
                addRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
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

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("Add a task…", text: $newTask)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused, equals: addFieldID)
                .onSubmit(commitNewTask)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { focused = addFieldID }
    }

    private func commitNewTask() {
        let trimmed = newTask.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        withAnimation(reorderSpring) { _ = store.addTask(trimmed) }
        newTask = ""
        focused = addFieldID // stay in the add field for rapid entry
    }

    private func focusRow(_ id: UUID) {
        DispatchQueue.main.async { focused = id }
    }

    /// Open the macOS share sheet (AirDrop, Messages, Mail…) for this note as a
    /// `.visor` file. AirDrop it to a nearby Mac and it drops straight onto that
    /// Mac's Visor; other channels send the file as an attachment.
    private func beamActiveNote() {
        guard let fileURL = store.writeBeamFile(),
              let view = hostWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [fileURL])
        let b = view.bounds
        let anchor = NSRect(x: b.midX - 1, y: b.maxY - 56, width: 2, height: 2)
        NSApp.activate(ignoringOtherApps: true) // accessory app must activate to show the sheet
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    /// Copy a shareable link to the clipboard — handy for channels where a link
    /// beats a file, and it carries an install link for friends without Visor.
    private func copyBeamLink() {
        guard let link = store.beamLink() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
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
    @FocusState.Binding var focused: UUID?
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

    @State private var hovering = false
    @State private var checkboxBump = false

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
        HStack(alignment: .center, spacing: 8) {
            // Drag handle — only this grabs for reordering, so dragging never
            // fights with editing the task text. A gesture-driven live reorder
            // (rows part as you drag) rather than a system drag-and-drop.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity((hovering || isDragging) && !suppressHover ? 0.95 : 0.45)
                // Generous invisible grab zone around the glyph, so you can grab
                // the general area instead of pixel-aiming the three lines. Wide
                // for an easy horizontal target; kept short so rows stay tight.
                .frame(width: 26, height: 20)
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

            // axis: .vertical lets long text wrap onto new lines and the row
            // grow, instead of truncating on a single line.
            TextField("", text: $item.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                // Prefer wrapping to the next line over growing horizontally —
                // without this the field stretches past the row edge and only
                // snaps to a new line a beat later.
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(item.isTask && item.done, color: .secondary)
                .foregroundStyle(item.isTask && item.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .focused($focused, equals: item.id)
                .onSubmit(onSubmit)

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
