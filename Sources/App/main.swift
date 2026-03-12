import AppKit

// Overline — Native Swift session label overlay for macOS
// Uses AXObserver for event-driven window tracking (~1-5ms latency)

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon, menu bar only

let delegate = AppDelegate()
app.delegate = delegate

print("[Overline] Starting...")
app.run()
