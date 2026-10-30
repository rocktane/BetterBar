import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private lazy var sections = SectionController(preferences: preferences)
    private lazy var watcher = MenuBarWatcher(sections: sections, preferences: preferences) { [weak self] point in
        self?.showContextMenu(at: point)
    }
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A main menu keeps an AXMenuBar published while Settings is
        // frontmost; without it, empty-space clicks cannot be recognised.
        NSApp.mainMenu = makeMainMenu()
        sections.start()
        watcher.start()

        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        if firstLaunch || !AXIsProcessTrusted() { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        sections.stop()
    }

    /// Opening the app again brings Settings forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Settings

    @objc func showSettings() {
        // Run after NSMenu has finished tracking and restored the previous app.
        DispatchQueue.main.async { [weak self] in self?.presentSettings() }
    }

    private func presentSettings() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.delegate = self
            window.title = "BetterBar"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(sections: sections, preferences: preferences))
            window.center()
            window.setFrameAutosaveName("Settings")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Menus

    private func showContextMenu(at point: NSPoint) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Réglages de BetterBar…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter BetterBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "BetterBar")
        appMenu.addItem(withTitle: "Réglages…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer BetterBar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quitter BetterBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}
