import AppKit
import Observation
import os

/// Owns the reveal state and keeps MenuBarAgent's restriction in sync with
/// it, the assignments and the running apps.
///
/// A section is a property of the app, chosen by a Cmd-drop or in Settings.
/// Hiding goes through the restriction, wherever the icons are: BetterBar
/// never moves them.
@MainActor
@Observable
final class SectionController {
    private nonisolated static let log = Logger(subsystem: "com.yohan.betterbar", category: "sections")

    let preferences: Preferences
    private(set) var state: RevealState = .collapsed
    private(set) var apps: [MenuBarApp] = []
    private(set) var lastError: String?

    @ObservationIgnored private let restriction = MenuBarRestriction()
    @ObservationIgnored private var installedIDs: Set<String> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var lastReveal: ContinuousClock.Instant?
    @ObservationIgnored private var deferredApply: Task<Void, Never>?

    /// Called after every state change, for the auto-hide clock.
    @ObservationIgnored var onStateChange: ((RevealState) -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        restriction.onFailure = { [weak self] error in self?.handleFailure(error) }
    }

    var isAvailable: Bool { MenuBarRestriction.isAvailable }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.systemChanged(app: app, name: name) }
            })
        }
        Task.detached(priority: .utility) {
            let ids = Inventory.installedBundleIDs()
            await MainActor.run { self.installedIDs = ids; self.apply() }
        }
        refresh()
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        deferredApply?.cancel()
        restriction.release()
    }

    // MARK: State

    /// Always Hidden is revealed only by an Option-click; any other click
    /// on empty space while it is revealed conceals everything again.
    func click(option: Bool, clickCount: Int = 1) {
        guard clickCount == 1 else { return }
        setState(state.afterClick(option: option))
    }

    func collapse() { setState(.collapsed) }

    func setState(_ new: RevealState) {
        guard new != state else { return }
        state = new
        Self.log.debug("reveal state: \(String(describing: new), privacy: .public)")
        retryCount = 0
        apply()
        onStateChange?(new)
    }

    // MARK: Holding everything revealed

    @ObservationIgnored private var holding = false

    /// Whether everything is revealed for a Cmd-drag, not because the user
    /// asked.
    var isHolding: Bool { holding }

    /// Reveals everything, so that every zone can receive an icon and the
    /// drop can be read.
    func beginHold() {
        guard !holding else { return }
        holding = true
        apply()
    }

    /// Ends the temporary reveal, applying the user's latest state.
    func endHold() {
        guard holding else { return }
        holding = false
        apply()
    }

    func setSection(_ section: BarSection, for app: MenuBarApp) {
        preferences.setSection(section, for: app)
        apply()
    }

    /// Whether MenuBarAgent currently draws this app's icons. Concealed
    /// icons keep stale frames in Accessibility.
    func isDisplayed(_ app: NSRunningApplication) -> Bool {
        guard let allowed = restriction.allowed else { return true }
        if let id = app.bundleIdentifier, SystemHosts.bundleIDs.contains(id) { return true }
        guard AppIdentity.isIdentifiable(bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path),
              let id = app.bundleIdentifier
        else { return false }
        return allowed.contains(id)
    }

    // MARK: Sync

    /// Rescans icons, then re-applies. Cheap enough to run on every app
    /// launch or quit and while Settings is open.
    func refresh() {
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let found = Inventory.scan()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if found != self.apps { self.apps = Self.merge(found, keepingConcealedFrom: self.apps, assignments: self.preferences.assignments) }
                self.apply()
            }
        }
    }

    /// Concealed icons can vanish from Accessibility on some apps; keep the
    /// last known entry for running apps so the list does not flicker.
    private static func merge(_ found: [MenuBarApp], keepingConcealedFrom old: [MenuBarApp], assignments: [String: BarSection]) -> [MenuBarApp] {
        let foundIDs = Set(found.map(\.id))
        let running = Set(NSWorkspace.shared.runningApplications.map { AppIdentity.key(bundleID: $0.bundleIdentifier, executableName: $0.executableURL?.lastPathComponent ?? "") })
        let kept = old.filter { !foundIDs.contains($0.id) && running.contains($0.id) && assignments[$0.id] != nil }
        return (found + kept).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func systemChanged(app: NSRunningApplication?, name: Notification.Name) {
        // MenuBarAgent restarting drops every restriction: re-assert.
        if app?.bundleIdentifier == "com.apple.MenuBarAgent" || name == NSWorkspace.didWakeNotification {
            restriction.release()
        }
        apply()
        // Icons appear a moment after launch.
        refresh()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.refresh()
        }
    }

    func apply() {
        guard isAvailable else { return }
        deferredApply?.cancel()
        deferredApply = nil
        let allowed = RestrictionPlanner.allowList(
            state: isHolding ? .allShown : state,
            assignments: preferences.assignments,
            running: runningProcesses(),
            knownBundleIDs: installedIDs
        )
        let current = restriction.isActive ? restriction.allowed : nil
        // Concealing icons still fading in would hide the sections one
        // after the other: wait until they have settled, then hide them all.
        if RestrictionPlanner.conceals(from: current, to: allowed), let lastReveal {
            let wait = lastReveal + RestrictionPlanner.revealSettle - .now
            if wait > .zero {
                deferredApply = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                    self?.apply()
                }
                return
            }
        }
        if RestrictionPlanner.reveals(from: current, to: allowed) { lastReveal = .now }
        guard let allowed else {
            if restriction.isActive { restriction.release() }
            return
        }
        guard !restriction.isActive || restriction.allowed != allowed else { return }
        restriction.apply(allowing: allowed)
        lastError = nil
    }

    /// Every running process, from NSWorkspace: hiding must not depend on
    /// the Accessibility inventory, which needs a permission.
    private func runningProcesses() -> [MenuBarApp] {
        NSWorkspace.shared.runningApplications.map { app in
            let exe = app.executableURL?.lastPathComponent ?? ""
            return MenuBarApp(id: AppIdentity.key(bundleID: app.bundleIdentifier, executableName: exe),
                              bundleID: app.bundleIdentifier, name: app.localizedName ?? exe,
                              bundlePath: app.bundleURL?.path, iconCount: 0)
        }
    }

    private func handleFailure(_ error: Error) {
        // Never release here: an unrestricted bar reveals Always Hidden. The
        // last confirmed restriction stays held; retry the latest one.
        lastError = error.localizedDescription
        guard retryCount < 5 else { return }
        retryCount += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.apply()
        }
    }
}
