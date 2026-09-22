import AppKit

// Top-level code in main.swift is nonisolated, but everything below is
// main-actor state (the delegate, the panel, the notch controller). This is
// the process's main thread by definition, so assert that rather than hop:
// a hop would run the app after main() returned.
// An ObjC exception on the main thread is otherwise caught by AppKit and
// logged, and the app carries on — with the Swift concurrency runtime's
// thread state left corrupt, so that a later, unrelated button or menu
// click crashes in MainActor.assumeIsolated with nothing in the report to
// say why. Crash at the exception instead: the report then names it.
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // Held for the process lifetime — NSApplication doesn't retain its delegate.
    objc_setAssociatedObject(app, "visor.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
