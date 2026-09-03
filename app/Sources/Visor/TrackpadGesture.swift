import Foundation

// MARK: - Private MultitouchSupport structs (must match the framework's layout)

private struct MTPoint { var x: Float = 0; var y: Float = 0 }
private struct MTReadout { var pos = MTPoint(); var vel = MTPoint() }

/// One finger in a multitouch frame. The field order and sizes mirror the
/// private `MTTouch`; only `normalized.pos` is read, but the whole struct has to
/// line up for that offset to be right.
private struct MTTouch {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var pathIndex: Int32 = 0
    var state: Int32 = 0
    var fingerID: Int32 = 0
    var handID: Int32 = 0
    var normalized = MTReadout()
    var zTotal: Float = 0
    var field9: Int32 = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var absolute = MTReadout()
    var field14: Int32 = 0
    var field15: Int32 = 0
    var zDensity: Float = 0
}

// A raw pointer, because a pointer-to-Swift-struct isn't C-representable; the
// callback rebinds it to MTTouch.
private typealias MTContactCallback =
    @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

/// The frame-by-frame detector. Lives outside the actor because the callback
/// runs on the framework's own thread; it only hops to the main actor to fire.
private final class SwipeDetector {
    static let shared = SwipeDetector()

    // Config, read live from UserDefaults so the Settings toggle takes effect.
    private var enabled: Bool { UserDefaults.standard.bool(forKey: TrackpadGesture.enabledKey) }
    /// Swipe direction that triggers, "down" (default) or "up".
    private var wantUp: Bool { UserDefaults.standard.string(forKey: TrackpadGesture.directionKey) == "up" }

    private var startY: Float?
    private var lastFire = Date.distantPast

    /// Called once per multitouch frame. `n` is the finger count.
    func frame(_ touches: UnsafeMutablePointer<MTTouch>?, _ n: Int32) {
        guard enabled, let touches else { startY = nil; return }
        guard n == 4 else { startY = nil; return }   // only a clean four-finger set

        var sum: Float = 0
        for i in 0..<4 { sum += touches[i].normalized.pos.y }
        let y = sum / 4

        guard let start = startY else { startY = y; return }
        let dy = y - start                 // normalized 0…1, y increases upward on the trackpad
        let threshold: Float = 0.18
        let movedUp = dy > threshold
        let movedDown = dy < -threshold
        guard movedUp || movedDown else { return }
        guard (movedUp == wantUp) else { startY = y; return }   // wrong direction, re-anchor

        // Debounce and require the fingers to lift before another fire.
        if Date().timeIntervalSince(lastFire) > 0.6 {
            lastFire = Date()
            Task { @MainActor in TrackpadGesture.shared.fire() }
        }
        startY = nil
    }
}

/// The C callback — a top-level function because a `@convention(c)` pointer
/// can't capture context. Forwards every frame to the detector.
private func mtFrameCallback(_ device: Int32, _ touches: UnsafeMutableRawPointer?,
                             _ n: Int32, _ timestamp: Double, _ frame: Int32) -> Int32 {
    SwipeDetector.shared.frame(touches?.assumingMemoryBound(to: MTTouch.self), n)
    return 0
}

/// Reads a raw four-finger swipe off the trackpad via the private
/// MultitouchSupport framework, and fires an action — used to open the HUD.
///
/// The public gesture APIs cap at three fingers and never report finger count
/// to a background listener, and four-finger up/down are consumed by Mission
/// Control before any app sees them, so this taps the device directly (the way
/// BetterTouchTool and Swish do). Loaded at runtime with `dlopen`, so if the
/// framework ever goes away this is a no-op rather than a launch failure.
@MainActor
final class TrackpadGesture {
    static let shared = TrackpadGesture()

    static let enabledKey = "visor.trackpadSwipe"
    static let directionKey = "visor.trackpadSwipeDirection"

    /// What a recognised swipe does. Set by the app delegate.
    var onSwipe: (() -> Void)?

    private var handle: UnsafeMutableRawPointer?
    private var devices: [UnsafeRawPointer] = []
    private var started = false

    // MTDeviceRef is an opaque pointer, so it's declared as a raw pointer.
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (UnsafeRawPointer, MTContactCallback) -> Void
    private typealias StartFn = @convention(c) (UnsafeRawPointer, Int32) -> Void

    /// Load the framework and start listening. Safe to call once at launch; the
    /// detector itself checks the Settings toggle, so this can run always and
    /// simply do nothing until the gesture is turned on.
    func startIfPossible() {
        guard !started else { return }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let h = dlopen(path, RTLD_LAZY) else { return }
        handle = h
        guard let createSym = dlsym(h, "MTDeviceCreateList"),
              let registerSym = dlsym(h, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(h, "MTDeviceStart") else { return }

        let createList = unsafeBitCast(createSym, to: CreateListFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        let start = unsafeBitCast(startSym, to: StartFn.self)

        guard let listRef = createList()?.takeRetainedValue() else { return }
        let count = CFArrayGetCount(listRef)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(listRef, i) else { continue }
            let device = UnsafeRawPointer(raw)
            register(device, mtFrameCallback)
            start(device, 0)
            devices.append(device)
        }
        started = !devices.isEmpty
    }

    /// Called from the detector (already hopped to the main actor).
    fileprivate func fire() { onSwipe?() }
}
