import AppKit
import Combine
import SwiftUI

/// The practice workspace: a small window Visor owns, with a fake expense
/// report and an empty Total field, so the introduction can show an agent
/// reading and typing on screen without touching anything real.
///
/// The actions are scripted. `ComputerUseAgent` refuses to drive Visor's
/// own windows for the length of a run (so it can't click its own card),
/// which rules out pointing the real agent at a window Visor owns. The
/// driver below moves a cursor ring, lights each row as it is "read", and
/// types the total a digit at a time — the same shape a real run has, at
/// a pace a person can follow, and interruptible between actions.
@MainActor
final class PracticeDriver: ObservableObject {
    enum Phase: Equatable { case idle, reading(Int), moving, typing(Int), done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var running = false
    /// Set when Stop halted it; cleared by Continue.
    @Published private(set) var stopped = false
    @Published private(set) var typed = ""
    @Published private(set) var cursor: CGPoint = .zero
    @Published private(set) var stops = 0
    @Published private(set) var completions = 0

    static let rows: [(item: String, amount: Int)] = [
        ("Taxi to the airport", 42),
        ("Hotel, two nights", 318),
        ("Client dinner", 96),
    ]
    static var total: Int { rows.reduce(0) { $0 + $1.amount } }

    /// Where things are inside the practice view, filled in by the view.
    var rowAnchors: [CGPoint] = []
    var fieldAnchor: CGPoint = .zero

    private var work: DispatchWorkItem?

    var canContinue: Bool { stopped }
    var isDone: Bool { phase == .done }

    func run() {
        guard !running, phase != .done else { return }
        running = true
        stopped = false
        if phase == .idle { step(.reading(0)) } else { resume() }
    }

    func stop() {
        guard running else { return }
        work?.cancel()
        running = false
        stopped = true
        stops += 1
    }

    func reset() {
        work?.cancel()
        phase = .idle
        running = false
        stopped = false
        typed = ""
    }

    private func resume() { advance() }

    private func step(_ next: Phase) {
        phase = next
        switch next {
        case .reading(let i):
            if rowAnchors.indices.contains(i) { glide(to: rowAnchors[i]) }
        case .moving:
            glide(to: fieldAnchor)
        case .typing(let i):
            let digits = Array(String(Self.total))
            typed = String(digits.prefix(i + 1))
        case .idle, .done:
            break
        }
        let delay: TimeInterval
        switch next {
        case .reading: delay = Design.Motion.reduced ? 0.3 : 0.9
        case .moving:  delay = Design.Motion.reduced ? 0.2 : 0.7
        case .typing:  delay = Design.Motion.reduced ? 0.15 : 0.45
        default:       delay = 0
        }
        if next == .done {
            running = false
            completions += 1
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.advance() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func advance() {
        guard running else { return }
        switch phase {
        case .idle:              step(.reading(0))
        case .reading(let i):    step(i + 1 < Self.rows.count ? .reading(i + 1) : .moving)
        case .moving:            step(.typing(0))
        case .typing(let i):     step(i + 1 < String(Self.total).count ? .typing(i + 1) : .done)
        case .done:              break
        }
    }

    private func glide(to point: CGPoint) {
        withAnimation(Design.Motion.animation(.spring(response: 0.55, dampingFraction: 0.82))) {
            cursor = point
        }
    }
}

/// The practice window itself: titled, small, centred under the notch.
@MainActor
enum PracticeWindow {
    static let size = CGSize(width: 480, height: 300)

    static func make(driver: PracticeDriver) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Practice — Visor"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Design.Retro.bg)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: PracticeView(driver: driver)
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)
        return window
    }

    /// Below the card, centred on the notch's screen.
    static func place(_ window: NSWindow, on screen: NSScreen, under cardBottom: CGFloat) {
        let x = screen.frame.midX - size.width / 2
        let y = max(screen.frame.minY + 80, cardBottom - size.height - 36)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The report. Every element the driver "touches" reports its centre so
/// the cursor ring has somewhere to go.
struct PracticeView: View {
    @ObservedObject var driver: PracticeDriver

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Design.Space.loose) {
                HStack(spacing: Design.Space.normal) {
                    SectionLabel("Practice", tint: Design.Retro.accent)
                    Text("Nothing here is real.")
                        .font(Design.Typography.caption())
                        .foregroundStyle(Design.Ink.tertiary)
                    Spacer()
                    if driver.running {
                        HStack(spacing: Design.Space.snug) {
                            DotMatrixIndicator(size: 10, tint: Design.Retro.accent)
                            Text(statusLine).font(Design.Typography.caption()).foregroundStyle(Design.Ink.secondary)
                        }
                    } else if driver.stopped {
                        Text("Stopped").font(Design.Typography.captionMedium()).foregroundStyle(Design.Ink.destructive)
                    } else if driver.isDone {
                        Text("Done").font(Design.Typography.captionMedium()).foregroundStyle(Design.Retro.accent)
                    }
                }

                Text("Expense report")
                    .font(Design.Typography.title())
                    .foregroundStyle(Design.Ink.primary)

                VStack(spacing: 2) {
                    ForEach(Array(PracticeDriver.rows.enumerated()), id: \.offset) { i, row in
                        HStack {
                            Text(row.item).font(Design.Typography.body()).foregroundStyle(Design.Ink.primary)
                            Spacer()
                            Text("$\(row.amount)").font(Design.Typography.mono()).foregroundStyle(Design.Ink.secondary)
                        }
                        .padding(.horizontal, Design.Space.roomy)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                            .fill(isReading(i) ? Design.Retro.accent.opacity(0.16) : Design.Surface.raised))
                        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                            .strokeBorder(isReading(i) ? Design.Retro.accent.opacity(0.6) : Design.Stroke.divider,
                                          lineWidth: Design.Stroke.hairline))
                        .background(GeometryReader { g in
                            Color.clear.preference(key: PracticeAnchorKey.self,
                                                   value: [i: CGPoint(x: g.frame(in: .named("practice")).midX,
                                                                      y: g.frame(in: .named("practice")).midY)])
                        })
                        .animation(Design.Motion.quick, value: driver.phase)
                    }
                }

                HStack(spacing: Design.Space.roomy) {
                    Text("Total").font(Design.Typography.heading()).foregroundStyle(Design.Ink.primary)
                    Spacer()
                    HStack(spacing: 2) {
                        Text("$").font(Design.Typography.mono()).foregroundStyle(Design.Ink.tertiary)
                        Text(driver.typed.isEmpty ? " " : driver.typed)
                            .font(Design.Typography.mono())
                            .foregroundStyle(Design.Ink.primary)
                        if case .typing = driver.phase, driver.running {
                            Rectangle().fill(Design.Retro.accent).frame(width: 1.5, height: 14)
                        }
                    }
                    .padding(.horizontal, Design.Space.roomy)
                    .frame(width: 120, height: Design.Metric.large, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .fill(Design.Surface.raisedStrong))
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .strokeBorder(driver.isDone ? Design.Retro.accent.opacity(0.8)
                                      : (isAtField ? Design.Retro.accent.opacity(0.6) : Design.Stroke.control),
                                      lineWidth: Design.Stroke.hairline))
                    .background(GeometryReader { g in
                        Color.clear.preference(key: PracticeAnchorKey.self,
                                               value: [99: CGPoint(x: g.frame(in: .named("practice")).midX,
                                                                   y: g.frame(in: .named("practice")).midY)])
                    })
                    .accessibilityIdentifier("visor.practice.total")
                }
                .padding(.top, Design.Space.tight)
            }
            .padding(Design.Space.section)

            // The cursor ring: where the "agent" is looking or typing.
            if driver.phase != .idle {
                Circle()
                    .strokeBorder(Design.Retro.accent, lineWidth: 2)
                    .background(Circle().fill(Design.Retro.accent.opacity(0.18)))
                    .frame(width: 22, height: 22)
                    .shadow(color: Design.Retro.accent.opacity(0.6), radius: 8)
                    .position(driver.cursor)
                    .allowsHitTesting(false)
                    .opacity(driver.isDone ? 0 : 1)
                    .animation(Design.Motion.quick, value: driver.isDone)
            }
        }
        .coordinateSpace(name: "practice")
        .onPreferenceChange(PracticeAnchorKey.self) { anchors in
            driver.rowAnchors = (0..<PracticeDriver.rows.count).compactMap { anchors[$0] }
            if let f = anchors[99] { driver.fieldAnchor = f }
        }
        .background(Design.Retro.bg)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("visor.practice")
    }

    private func isReading(_ i: Int) -> Bool {
        if case .reading(let r) = driver.phase { return r == i && driver.running }
        return false
    }

    private var isAtField: Bool {
        switch driver.phase {
        case .moving, .typing: return true
        default: return false
        }
    }

    private var statusLine: String {
        switch driver.phase {
        case .reading(let i): return "Reading line \(i + 1) of \(PracticeDriver.rows.count)"
        case .moving:         return "Moving to Total"
        case .typing:         return "Typing the total"
        default:              return ""
        }
    }
}

private struct PracticeAnchorKey: PreferenceKey {
    static var defaultValue: [Int: CGPoint] = [:]
    static func reduce(value: inout [Int: CGPoint], nextValue: () -> [Int: CGPoint]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
