import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Bridge the top-level (non-isolated) main.swift into MainActor isolation so
// the @MainActor-annotated AppDelegate can be constructed (CR-01). Safe at
// runtime: this file runs on the process main thread before NSApp.run().
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
