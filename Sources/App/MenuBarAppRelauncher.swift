import AppKit

/// Captures icon owners before changing preferences, then restarts only those apps.
/// Uses normal termination: an app can refuse to quit to protect unsaved work.
@MainActor
struct MenuBarAppRelauncher {
    struct Target: Identifiable {
        let app: NSRunningApplication
        let url: URL
        var id: pid_t { app.processIdentifier }
        var name: String { app.localizedName ?? url.deletingPathExtension().lastPathComponent }
    }

    func targets() async -> [Target] {
        let pids = await Task.detached { Set(Inventory.statusItems().map(\.pid)) }.value
        return pids.compactMap { pid in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app != .current, !app.isTerminated,
                  let url = app.bundleURL, url.pathExtension == "app",
                  !url.path.hasPrefix("/System/"),
                  let bundleID = app.bundleIdentifier,
                  !SystemHosts.bundleIDs.contains(bundleID),
                  !bundleID.hasPrefix("com.apple.")
            else { return nil }
            return Target(app: app, url: url)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Each target was shown in the confirmation. Never force-quit an app.
    func relaunch(_ targets: [Target]) async -> [String] {
        let tasks = targets.map { target in
            Task { @MainActor () -> String? in
                await relaunch(target) ? nil : target.name
            }
        }
        var failed: [String] = []
        for task in tasks {
            if let name = await task.value { failed.append(name) }
        }
        return failed.sorted()
    }

    private func relaunch(_ target: Target) async -> Bool {
        // Do not act on a replacement process launched since confirmation.
        guard !target.app.isTerminated else { return true }
        guard target.app.terminate() else { return false }
        let deadline = Date().addingTimeInterval(8)
        while !target.app.isTerminated && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard target.app.isTerminated else { return false }
        if let id = target.app.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
               !$0.isTerminated && $0.bundleURL == target.url
           }) {
            return true // A login item may already have restarted itself.
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            let app = try await NSWorkspace.shared.openApplication(at: target.url, configuration: configuration)
            return !app.isTerminated
        } catch {
            return false
        }
    }
}
