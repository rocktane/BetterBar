import AppKit

/// Reads the status area through Accessibility, to find out which zone a
/// Cmd-dropped icon landed in, or where a brand-new icon was added.
///
/// Only icons MenuBarAgent currently draws are read: a concealed icon has a
/// stale frame.
@MainActor
final class BarReader {
    private let sections: SectionController
    /// Vertical centre of each item of the last read, for synthetic drags.
    private(set) var midY: [String: Double] = [:]

    init(sections: SectionController) {
        self.sections = sections
    }

    /// Reads the bar once it has stopped moving: MenuBarAgent takes a few
    /// hundred milliseconds to settle after a drop.
    func settledItems() async -> [BarItem] {
        // MenuBarAgent applies a drop only after a while; until then two
        // reads agree on the old layout.
        try? await Task.sleep(for: .milliseconds(500))
        var previous: [BarItem]?
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(120))
            let current = await items()
            if current == previous { return current }
            previous = current
        }
        return previous ?? []
    }

    private func items() async -> [BarItem] {
        let raw = await Task.detached(priority: .userInitiated) { Inventory.statusItems() }.value
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // A restriction may conceal the separators too: their frames are
        // then stale.
        let separatorsDrawn = sections.isDisplayed(.current)
        var result: [BarItem] = []
        var midY: [String: Double] = [:]
        for status in raw {
            guard let process = NSRunningApplication(processIdentifier: status.pid) else { continue }
            let key = Self.key(of: process)
            let kind: BarItem.Kind
            if status.pid == ownPID {
                guard separatorsDrawn else { continue }
                kind = .separator
            } else if Self.isApple(process) {
                kind = .fixed
            } else {
                guard sections.isDisplayed(process) else { continue }
                kind = .icon(sections.preferences.section(for: key))
            }
            let id = "\(status.pid):\(status.index)"
            result.append(BarItem(id: id, owner: key, kind: kind,
                                  minX: Double(status.frame.minX), maxX: Double(status.frame.maxX)))
            midY[id] = Double(status.frame.midY)
        }
        self.midY = midY
        return result.sorted { $0.minX < $1.minX }
    }

    /// Apple's own hosts (Clock, Control Center…): never concealed, managed
    /// in System Settings > Menu Bar.
    static func isApple(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, SystemHosts.bundleIDs.contains(id) { return true }
        return app.bundleURL?.path.hasPrefix("/System/Library/CoreServices/") == true
    }

    static func key(of app: NSRunningApplication) -> String {
        AppIdentity.key(bundleID: app.bundleIdentifier, executableName: app.executableURL?.lastPathComponent ?? "")
    }
}
