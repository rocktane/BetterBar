import AppKit

// Minimal runner: `make test`; spacing tests use an isolated preferences domain.
nonisolated(unsafe) var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL line \(line): \(message)") }
}

func app(_ id: String, path: String = "/Applications/X.app", icons: Int = 1) -> MenuBarApp {
    MenuBarApp(id: id, bundleID: id.hasPrefix("exe:") ? nil : id, name: id, bundlePath: path, iconCount: icons)
}

// MARK: Reveal state

check(RevealState.collapsed.afterClick(option: false) == .hiddenShown, "click reveals Hidden")
check(RevealState.hiddenShown.afterClick(option: false) == .collapsed, "click again conceals")
check(RevealState.collapsed.afterClick(option: true) == .allShown, "option-click reveals all")
check(RevealState.hiddenShown.afterClick(option: true) == .allShown, "option-click from Hidden reveals all")
check(RevealState.allShown.afterClick(option: false) == .collapsed, "click from all conceals")
check(RevealState.allShown.afterClick(option: true) == .collapsed, "option-click from all conceals")
check(RevealState.hiddenShown.concealedSections == [.alwaysHidden], "Hidden shown keeps Always Hidden concealed")

// A temporary reveal for arranging must never become the user's toggle state.
let interactionDomain = "com.yohan.betterbar.interaction-tests.\(UUID().uuidString)"
let interactionDefaults = UserDefaults(suiteName: interactionDomain)!
let interaction = SectionController(preferences: Preferences(defaults: interactionDefaults))
interaction.beginHold()
check(interaction.state == .collapsed, "internal hold preserves the user's collapsed state")
interaction.click(option: false)
check(interaction.state == .hiddenShown, "click during hold reveals only Hidden")
interaction.endHold()
check(interaction.state == .hiddenShown, "ending hold preserves the latest click")
interaction.click(option: false)
check(interaction.state == .collapsed, "second click conceals Hidden")
interaction.click(option: true)
interaction.click(option: false)
interaction.click(option: false)
check(interaction.state == .hiddenShown, "after concealing all, next click reveals only Hidden")
interactionDefaults.removePersistentDomain(forName: interactionDomain)

// MARK: Allow list

let running = [app("com.a"), app("com.h"), app("com.ah"), app("eu.exelban.Stats", icons: 5)]
let assignments: [String: BarSection] = ["com.h": .hidden, "com.ah": .alwaysHidden, "eu.exelban.Stats": .hidden]

let collapsed = RestrictionPlanner.allowList(state: .collapsed, assignments: assignments, running: running, knownBundleIDs: ["com.installed"])
check(collapsed != nil, "collapsed holds a restriction")
check(collapsed?.contains("com.a") == true, "visible app allowed")
check(collapsed?.contains("com.installed") == true, "installed apps pre-allowed")
check(collapsed?.contains("com.apple.controlcenter") == true, "system hosts allowed")
check(collapsed?.contains("com.h") == false && collapsed?.contains("com.ah") == false, "concealed apps excluded")
check(collapsed?.contains("eu.exelban.Stats") == false, "multi-icon app concealed as a whole")

let hiddenShown = RestrictionPlanner.allowList(state: .hiddenShown, assignments: assignments, running: running, knownBundleIDs: [])
check(hiddenShown?.contains("com.h") == true && hiddenShown?.contains("com.ah") == false, "Hidden shown, Always Hidden not")

check(RestrictionPlanner.allowList(state: .allShown, assignments: assignments, running: running, knownBundleIDs: []) == nil, "all shown releases")
check(RestrictionPlanner.allowList(state: .collapsed, assignments: [:], running: running, knownBundleIDs: []) == nil, "nothing assigned, nothing held")
check(RestrictionPlanner.allowList(state: .hiddenShown, assignments: ["com.h": .hidden], running: running, knownBundleIDs: []) == nil,
      "no Always Hidden app running, nothing held while Hidden shown")
check(RestrictionPlanner.allowList(state: .collapsed, assignments: ["com.gone": .hidden], running: running, knownBundleIDs: ["com.gone"]) == nil,
      "concealed app not running, nothing held")
let known = RestrictionPlanner.allowList(state: .collapsed, assignments: ["com.h": .hidden], running: running, knownBundleIDs: ["com.h"])
check(known?.contains("com.h") == false, "a known bundle id never overrides concealment")

// MARK: Identity

check(AppIdentity.isIdentifiable(bundleID: "a", bundlePath: "/Applications/A.app"), "/Applications")
check(AppIdentity.isIdentifiable(bundleID: "a", bundlePath: "/Applications/Folder/A.app"), "/Applications sub-folder")
check(!AppIdentity.isIdentifiable(bundleID: "a", bundlePath: NSHomeDirectory() + "/Applications/A.app"), "~/Applications")
check(!AppIdentity.isIdentifiable(bundleID: "a", bundlePath: "/Users/x/code/build/A.app"), "build folder")
check(!AppIdentity.isIdentifiable(bundleID: nil, bundlePath: "/Applications/A.app"), "no bundle id")
check(AppIdentity.key(bundleID: nil, executableName: "tool") == "exe:tool", "key without bundle id")

// MARK: Click classification

check(ClickClassifier.isEmptySpace([.bar]), "bar is empty")
check(!ClickClassifier.isEmptySpace([.icon]), "icon is not empty")
check(!ClickClassifier.isEmptySpace([.appMenu]), "app menu is not empty")
check(!ClickClassifier.isEmptySpace([.other]), "unknown is not empty")
check(!ClickClassifier.isEmptySpace([.bar, .icon]), "mirrored icon vetoes")
check(ClickClassifier.isEmptySpace([.bar, .other, .bar]), "mirrors agreeing")
check(!ClickClassifier.isEmptySpace([]), "no probe")
let xs = ClickClassifier.mirroredXs(x: 2900, from: (1800, 3000), to: (0, 1800))
check(xs.contains(1700), "right-aligned mirror")
check(xs.contains(1100), "left-aligned mirror")

// MARK: Bar layout

func sep(_ id: String, _ x: Double) -> BarItem { BarItem(id: id, owner: "self", kind: .separator, minX: x - 1, maxX: x + 1) }
func icon(_ id: String, _ x: Double, _ section: BarSection = .visible, owner: String? = nil) -> BarItem {
    BarItem(id: id, owner: owner ?? id, kind: .icon(section), minX: x - 10, maxX: x + 10)
}

check(BarLayout.zone(atX: 100, separatorMidXs: [200, 150]) == .alwaysHidden, "left of both")
check(BarLayout.zone(atX: 170, separatorMidXs: [200, 150]) == .hidden, "between")
check(BarLayout.zone(atX: 250, separatorMidXs: [150, 200]) == .visible, "right of both")
check(BarLayout.zone(atX: 250, separatorMidXs: [150]) == nil, "missing separator")

let stats = [sep("L", 150), sep("R", 200), icon("s1", 170, owner: "stats"), icon("s2", 230, owner: "stats"), icon("s3", 260, owner: "stats")]
check(BarLayout.droppedSection(stats, owner: "stats", dropX: 175) == .hidden, "nearest icon of a multi-icon app")
check(BarLayout.droppedSection(stats, owner: "other", dropX: 175) == nil, "no icon")

/// Applies a move the way MenuBarAgent does: the icon passes every
/// neighbour whose centre the pointer crosses, then everything is re-laid
/// out at a fixed pitch.
func simulate(_ items: [BarItem], _ move: BarMove) -> [BarItem] {
    var ordered = items.sorted { $0.midX < $1.midX }
    let index = ordered.firstIndex { $0.id == move.itemID }!
    let moved = ordered.remove(at: index)
    let insertAt = ordered.firstIndex { $0.midX > move.toX } ?? ordered.count
    ordered.insert(moved, at: insertAt)
    return ordered.enumerated().map { i, item in
        let x = 100 + Double(i) * 30
        return BarItem(id: item.id, owner: item.owner, kind: item.kind, minX: x - 10, maxX: x + 10)
    }
}

func arranged(_ items: [BarItem]) -> (items: [BarItem], moves: Int) {
    var items = items, moves = 0
    while let move = BarLayout.nextMove(items), moves < 50 { items = simulate(items, move); moves += 1 }
    return (items, moves)
}

func order(_ items: [BarItem]) -> [String] { items.sorted { $0.midX < $1.midX }.map(\.id) }

let tidy = [icon("ah", 100, .alwaysHidden), sep("L", 130), icon("h", 160, .hidden), sep("R", 190), icon("v", 220)]
check(BarLayout.misplaced(tidy).isEmpty && BarLayout.nextMove(tidy) == nil, "tidy bar needs nothing")

// A new app appears left of everything but is Visible.
let fresh = arranged([icon("new", 100), icon("ah", 130, .alwaysHidden), sep("L", 160), icon("h", 190, .hidden), sep("R", 220), icon("v", 250)])
check(order(fresh.items) == ["ah", "L", "h", "R", "new", "v"], "new visible icon goes right of the separators: \(order(fresh.items))")
check(fresh.moves == 1, "one move")

// Everything misplaced, with empty zones: each lands in its zone, in order.
let messy = arranged([sep("L", 100), sep("R", 130), icon("h1", 160, .hidden), icon("v1", 190), icon("ah1", 220, .alwaysHidden),
                      icon("h2", 250, .hidden), icon("ah2", 280, .alwaysHidden)])
check(BarLayout.misplaced(messy.items).isEmpty, "messy bar ends tidy: \(order(messy.items))")
check(order(messy.items) == ["ah1", "ah2", "L", "h1", "h2", "R", "v1"], "relative order kept: \(order(messy.items))")

// Several visible icons left of the separators keep their order.
let lefties = arranged([icon("a", 100), icon("b", 130), icon("c", 160), sep("L", 190), sep("R", 220), icon("v", 250)])
check(order(lefties.items) == ["L", "R", "a", "b", "c", "v"], "visible icons keep order: \(order(lefties.items))")

// Every icon of a multi-icon app follows the app's section.
let split = arranged([icon("s1", 100, .hidden, owner: "stats"), sep("L", 130), sep("R", 160), icon("x", 190), icon("s2", 220, .hidden, owner: "stats")])
check(order(split.items) == ["L", "s1", "s2", "R", "x"], "multi-icon app gathered: \(order(split.items))")

let apple = BarItem(id: "clock", owner: "com.apple.MenuBarAgent", kind: .fixed, minX: 90, maxX: 110)
check(BarLayout.nextMove([apple, sep("L", 130), sep("R", 160)]) == nil, "Apple's items are never moved")
let pastApple = arranged([icon("a", 70), apple, sep("L", 130), sep("R", 160)])
check(order(pastApple.items) == ["clock", "L", "R", "a"], "Apple's items still count as neighbours: \(order(pastApple.items))")
check(BarLayout.nextMove([icon("v", 100), sep("L", 130)]) == nil, "nothing to do without both separators")
check(BarLayout.nextMove([icon("v", 100), sep("L", 130), sep("R", 160)], skipping: ["v"]) == nil, "stuck icons are skipped")

// MARK: Auto-hide

let t0 = Date()
var clock = AutoHideClock(delay: 5, now: t0)
check(!clock.tick(busy: true, now: t0 + 10), "busy never hides")
check(!clock.tick(busy: false, now: t0 + 14), "4 s away")
check(clock.tick(busy: false, now: t0 + 15), "5 s away hides")
var never = AutoHideClock(delay: nil, now: t0)
check(!never.tick(busy: false, now: t0 + 3600), "disabled never hides")

// Use the same window classifier as the live auto-hide timer.
let menuBars = [CGRect(x: 0, y: 0, width: 1800, height: 39)]
var menuWindow: [String: Any] = [
    kCGWindowLayer as String: Int(CGWindowLevelForKey(.mainMenuWindow)),
    kCGWindowOwnerPID as String: pid_t(123),
    kCGWindowOwnerName as String: "Example",
    kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 1800, height: 39).dictionaryRepresentation,
]
check(!MenuBarGeometry.isIconMenuWindow(menuWindow, ownPID: 456, menuBars: menuBars), "the menu bar itself must not block auto-hide")
// Itsycal's actual popover uses the main-menu level (24), just below
// the menu bar: rejecting that entire level hides icons during its use.
menuWindow[kCGWindowBounds as String] = CGRect(x: 1495, y: 41, width: 212, height: 878).dictionaryRepresentation
check(MenuBarGeometry.isIconMenuWindow(menuWindow, ownPID: 456, menuBars: menuBars), "menu-level popover pauses auto-hide")
menuWindow[kCGWindowLayer as String] = Int(CGWindowLevelForKey(.popUpMenuWindow))
check(MenuBarGeometry.isIconMenuWindow(menuWindow, ownPID: 456, menuBars: menuBars), "open icon menu pauses auto-hide")
var menuClock = AutoHideClock(delay: 5, now: t0)
check(!menuClock.tick(busy: true, now: t0 + 20), "open menu keeps icons shown")
check(!menuClock.tick(busy: false, now: t0 + 24.9), "wait full delay after menu closes")
check(menuClock.tick(busy: false, now: t0 + 25), "hide five seconds after menu closes")
menuWindow[kCGWindowAlpha as String] = 0.0
check(!MenuBarGeometry.isIconMenuWindow(menuWindow, ownPID: 456, menuBars: menuBars), "invisible menu cannot block auto-hide")
menuWindow[kCGWindowAlpha as String] = 1.0
menuWindow[kCGWindowBounds as String] = CGRect(x: 1900, y: 39, width: 200, height: 300).dictionaryRepresentation
check(!MenuBarGeometry.isIconMenuWindow(menuWindow, ownPID: 456, menuBars: menuBars), "window outside display cannot block auto-hide")

// MARK: System spacing (isolated domain, never global preferences)

let spacingDomain = "com.yohan.betterbar.spacing-tests.\(UUID().uuidString)" as CFString
let spacingKeys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
@MainActor
func spacingPreference(_ key: String, host: CFString = kCFPreferencesCurrentHost) -> Any? {
    CFPreferencesCopyValue(key as CFString, spacingDomain, kCFPreferencesCurrentUser, host)
}
@MainActor
func setSpacingPreference(_ key: String, value: Int, host: CFString) {
    CFPreferencesSetValue(key as CFString, NSNumber(value: value), spacingDomain, kCFPreferencesCurrentUser, host)
    CFPreferencesSynchronize(spacingDomain, kCFPreferencesCurrentUser, host)
}
let spacing = MenuBarSpacing(domain: spacingDomain)
check(spacing.value == 16 && !spacing.hasOverride && !spacing.hasChanges, "fresh spacing uses Apple defaults")
check(spacingKeys.allSatisfy { spacingPreference($0) == nil }, "reading spacing does not write overrides")
spacing.value = 8
check(spacingKeys.allSatisfy { spacingPreference($0) == nil }, "moving the slider does not write before Apply")
do {
    try spacing.apply()
    check(spacingKeys.allSatisfy { (spacingPreference($0) as? NSNumber)?.intValue == 8 }, "Apply persists both system preferences")
    let reopened = MenuBarSpacing(domain: spacingDomain)
    check(reopened.value == 8 && reopened.hasOverride && !reopened.hasChanges, "reopening reads existing spacing")
    spacing.value = 0
    try spacing.apply()
    check(spacingKeys.allSatisfy { (spacingPreference($0) as? NSNumber)?.intValue == 0 }, "minimum spacing is saved as zero, not removed")
    spacing.value = 32
    try spacing.apply()
    check(spacingKeys.allSatisfy { (spacingPreference($0) as? NSNumber)?.intValue == 32 }, "spacing can increase")
    setSpacingPreference("NSStatusItemSpacing", value: 12, host: kCFPreferencesAnyHost)
    setSpacingPreference("unrelated", value: 42, host: kCFPreferencesAnyHost)
    try spacing.reset()
    check(spacing.value == 16 && !spacing.hasOverride && !spacing.hasChanges, "Reset returns the UI to Apple defaults")
    check(spacingKeys.allSatisfy { spacingPreference($0) == nil && spacingPreference($0, host: kCFPreferencesAnyHost) == nil }, "Reset removes overrides in both scopes")
    check((spacingPreference("unrelated", host: kCFPreferencesAnyHost) as? NSNumber)?.intValue == 42, "Reset preserves unrelated preferences")
    setSpacingPreference("NSStatusItemSpacing", value: 6, host: kCFPreferencesAnyHost)
    let inherited = MenuBarSpacing(domain: spacingDomain)
    check(inherited.value == 6, "existing all-host settings are displayed")
    inherited.value = 16
    try inherited.apply()
    check(spacingKeys.allSatisfy { spacingPreference($0) == nil && spacingPreference($0, host: kCFPreferencesAnyHost) == nil }, "applying the Apple value removes overrides")
} catch {
    check(false, "spacing persistence failed: \(error)")
}
for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
    for key in spacingKeys + ["unrelated"] {
        CFPreferencesSetValue(key as CFString, nil, spacingDomain, kCFPreferencesCurrentUser, host)
    }
    CFPreferencesSynchronize(spacingDomain, kCFPreferencesCurrentUser, host)
}

print(failures == 0 ? "All tests passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
