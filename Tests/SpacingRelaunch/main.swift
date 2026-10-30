import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureURL = folder.appendingPathComponent("SpacingFixture.app")
let reportURL = folder.appendingPathComponent("frames.json")
let refusalURL = folder.appendingPathComponent("refuse")
let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
let hosts = [kCFPreferencesCurrentHost, kCFPreferencesAnyHost]
let saved = hosts.map { host in keys.map { CFPreferencesCopyValue($0 as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host) } }
@MainActor func restore() {
    for (i, host) in hosts.enumerated() {
        for (j, key) in keys.enumerated() {
            CFPreferencesSetValue(key as CFString, saved[i][j], kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host)
    }
}
struct Failure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }
}
@MainActor func report(pid: pid_t) async throws -> Double {
    for _ in 0..<50 {
        if let data = try? Data(contentsOf: reportURL),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
           values["pid"] == Double(pid), let distance = values["distance"], distance > 0 {
            return distance
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure(message: "No visible menu bar geometry for fixture PID \(pid)")
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
    var fixture: NSRunningApplication?
    var code: Int32 = 0
    do {
        let spacing = MenuBarSpacing()
        spacing.value = 32
        try spacing.apply()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let original = try await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: config)
        fixture = original
        let before = try await report(pid: original.processIdentifier)
        spacing.value = 0
        try spacing.apply()
        try await Task.sleep(for: .milliseconds(500))
        let unchanged = try await report(pid: original.processIdentifier)
        try require(before == unchanged, "Write-only must leave the running app unchanged")
        let relauncher = MenuBarAppRelauncher()
        let targets = await relauncher.targets()
        try require(targets.contains(where: { $0.id == original.processIdentifier }), "Discovery must include the icon owner")
        try require(!targets.contains(where: { $0.id == ProcessInfo.processInfo.processIdentifier }), "Discovery must exclude BetterBar itself")
        let target = MenuBarAppRelauncher.Target(app: original, url: fixtureURL)
        try Data().write(to: refusalURL)
        let refused = await relauncher.relaunch([target])
        try require(refused.count == 1 && !original.isTerminated, "Refusing to quit must preserve the app and report failure")
        try FileManager.default.removeItem(at: refusalURL)
        let failures = await relauncher.relaunch([target])
        try require(failures.isEmpty, "Fixture must relaunch successfully")
        guard let replacement = NSRunningApplication.runningApplications(withBundleIdentifier: "com.yohan.betterbar.spacingfixture").first else {
            throw Failure(message: "No replacement process")
        }
        fixture = replacement
        try require(replacement.processIdentifier != original.processIdentifier, "Relaunch must produce a fresh process")
        let after = try await report(pid: replacement.processIdentifier)
        try require(before - after >= 30, "Relaunch must reduce actual icon spacing")
        print("PASS: write-only preserves \(before) pt; refusal preserves process; relaunch reduces spacing to \(after) pt")
    } catch {
        print("FAIL: \(error)")
        code = 1
    }
    try? FileManager.default.removeItem(at: refusalURL)
    fixture?.terminate()
    restore()
    exit(code)
}
application.run()
