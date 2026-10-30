import Foundation

/// Where the user put an app's menu bar icons.
///
/// On macOS 27 concealment works per application: every icon of an app
/// (Stats has five) follows the app's section.
enum BarSection: String, Codable, CaseIterable, Sendable {
    case visible
    case hidden
    case alwaysHidden
}

/// What is currently revealed.
enum RevealState: Equatable, Sendable {
    /// Hidden and Always Hidden are concealed.
    case collapsed
    /// Hidden is revealed, Always Hidden stays concealed.
    case hiddenShown
    /// Everything is revealed; no restriction is held at all.
    case allShown

    var concealedSections: Set<BarSection> {
        switch self {
        case .collapsed: [.hidden, .alwaysHidden]
        case .hiddenShown: [.alwaysHidden]
        case .allShown: []
        }
    }

    var isRevealing: Bool { self != .collapsed }

    /// A click on an empty part of the menu bar.
    func afterClick(option: Bool) -> RevealState {
        switch (self, option) {
        case (.collapsed, false): .hiddenShown
        case (.collapsed, true): .allShown
        case (.hiddenShown, false): .collapsed
        case (.hiddenShown, true): .allShown
        case (.allShown, _): .collapsed
        }
    }
}

/// An application that owns at least one menu bar icon.
struct MenuBarApp: Identifiable, Equatable, Sendable {
    /// Stable key used for assignments: the bundle identifier, or
    /// `exe:<name>` for a process without one.
    let id: String
    let bundleID: String?
    let name: String
    let bundlePath: String?
    let iconCount: Int

    /// Whether MenuBarAgent can match this app against an allow list.
    var isIdentifiable: Bool { AppIdentity.isIdentifiable(bundleID: bundleID, bundlePath: bundlePath) }
}

enum AppIdentity {
    /// MenuBarAgent only resolves a status item's owner to a bundle
    /// identifier when the app runs from `/Applications` (sub-folders
    /// included) or from the system. Anything else (a build folder,
    /// `~/Applications`, an App Translocation path) is registered with a
    /// nil owner, so an allow list can never name it: it is concealed for
    /// as long as any restriction is held.
    ///
    /// Observed on macOS 27.0.1 (26A434); see README, "macOS 27".
    static func isIdentifiable(bundleID: String?, bundlePath: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty, let bundlePath else { return false }
        let path = (bundlePath as NSString).resolvingSymlinksInPath
        return trustedRoots.contains { path.hasPrefix($0) }
    }

    static let trustedRoots = ["/Applications/", "/System/Applications/", "/System/Library/"]

    static func key(bundleID: String?, executableName: String) -> String {
        if let bundleID, !bundleID.isEmpty { return bundleID }
        return "exe:\(executableName)"
    }
}

/// Bundle identifiers that host Apple's own items. They are never offered
/// for assignment and are always allowed.
enum SystemHosts {
    static let bundleIDs: Set<String> = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
        "com.apple.Spotlight",
        "com.apple.Siri",
        "com.apple.notificationcenterui",
        "com.apple.screencaptureui",
    ]
}

enum RestrictionPlanner {
    /// The bundle identifiers to allow, or nil when no restriction should
    /// be held (nothing running needs concealing).
    ///
    /// The restriction is an allow list: whatever it does not name is
    /// concealed. So it names every bundle we know of (running apps,
    /// installed apps, previously seen apps) minus the concealed ones, so
    /// an app launched while collapsed shows up immediately instead of
    /// waiting for the next refresh.
    static func allowList(
        state: RevealState,
        assignments: [String: BarSection],
        running: [MenuBarApp],
        knownBundleIDs: Set<String>
    ) -> Set<String>? {
        let concealedSections = state.concealedSections
        guard !concealedSections.isEmpty else { return nil }

        let concealedKeys = Set(assignments.compactMap { key, section in
            concealedSections.contains(section) ? key : nil
        })
        let needsRestriction = running.contains { concealedKeys.contains($0.id) }
        guard needsRestriction else { return nil }

        var allowed = knownBundleIDs.union(SystemHosts.bundleIDs)
        for app in running { if let id = app.bundleID { allowed.insert(id) } }
        allowed.subtract(concealedKeys)
        return allowed
    }
}

/// Decides when revealed sections close again.
struct AutoHideClock: Sendable {
    /// Seconds the pointer must stay away from the menu bar; nil disables.
    var delay: TimeInterval?
    private(set) var lastBusy: Date

    init(delay: TimeInterval?, now: Date = Date()) {
        self.delay = delay
        self.lastBusy = now
    }

    /// The menu bar is "busy" while the pointer is over it, a button is
    /// held (a Cmd-drag), or a menu or popover from an icon is open.
    mutating func tick(busy: Bool, now: Date) -> Bool {
        if busy { lastBusy = now; return false }
        guard let delay else { return false }
        return now.timeIntervalSince(lastBusy) >= delay
    }

    mutating func reset(now: Date) { lastBusy = now }
}
