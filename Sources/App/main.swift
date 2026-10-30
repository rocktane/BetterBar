import AppKit

let delegate = MainActor.assumeIsolated { AppDelegate() }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
