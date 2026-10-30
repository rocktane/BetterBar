import AppKit

// AppKit adds spacing around status items even when their length is zero.
// Only BetterBar's separators should lose that padding; other apps keep
// the user's global menu bar spacing. Set this before creating NSApplication.
UserDefaults.standard.set(0, forKey: "NSStatusItemSpacing")
UserDefaults.standard.set(0, forKey: "NSStatusItemSelectionPadding")

let delegate = MainActor.assumeIsolated { AppDelegate() }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
