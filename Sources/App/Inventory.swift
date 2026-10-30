import AppKit
import ApplicationServices

/// Lists the apps that currently own menu bar icons, through Accessibility.
///
/// On macOS 27 icons are no longer windows (MenuBarAgent composites the
/// whole bar), so `CGWindowList` cannot see them. Each app still exposes
/// its icons as children of its `AXExtrasMenuBar`.
enum Inventory {
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Blocking: one AX round trip per running app, bounded by a short
    /// timeout. Call off the main thread.
    nonisolated static func scan() -> [MenuBarApp] {
        var byKey: [String: MenuBarApp] = [:]
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            if let id = app.bundleIdentifier, SystemHosts.bundleIDs.contains(id) { continue }
            if app.bundleURL?.path.hasPrefix("/System/Library/CoreServices/") == true { continue }
            let count = iconCount(pid: app.processIdentifier)
            guard count > 0 else { continue }
            let exe = app.executableURL?.lastPathComponent ?? "pid \(app.processIdentifier)"
            let key = AppIdentity.key(bundleID: app.bundleIdentifier, executableName: exe)
            let existing = byKey[key]?.iconCount ?? 0
            byKey[key] = MenuBarApp(
                id: key,
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? exe,
                bundlePath: app.bundleURL?.path,
                iconCount: existing + count
            )
        }
        return byKey.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func iconCount(pid: pid_t) -> Int {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return 0 }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(bar as! AXUIElement, kAXChildrenAttribute as CFString, &count) == .success else { return 0 }
        return count
    }

    /// One status item as Accessibility reports it (top-left origin).
    struct StatusItem: Equatable, Sendable {
        let pid: pid_t
        let index: Int
        let frame: CGRect
    }

    /// Every status item on the bar, BetterBar's separators and Apple's
    /// items included. Icons of a concealed app keep stale frames: callers
    /// must drop them. Blocking; call off the main thread.
    nonisolated static func statusItems() -> [StatusItem] {
        NSWorkspace.shared.runningApplications.flatMap { app in
            frames(pid: app.processIdentifier).enumerated().map { index, frame in
                StatusItem(pid: app.processIdentifier, index: index, frame: frame)
            }
        }
    }

    private nonisolated static func frames(pid: pid_t) -> [CGRect] {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return [] }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let icons = children as? [AXUIElement]
        else { return [] }
        return icons.compactMap { icon in
            var position: AnyObject?, size: AnyObject?
            var point = CGPoint.zero, extent = CGSize.zero
            guard AXUIElementCopyAttributeValue(icon, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(icon, kAXSizeAttribute as CFString, &size) == .success,
                  AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent),
                  point.x >= 0
            else { return nil }
            return CGRect(origin: point, size: extent)
        }
    }

    /// Bundle identifiers of installed apps that MenuBarAgent can identify.
    /// Allowing them up front means an app launched while sections are
    /// concealed appears at once, without a refresh.
    nonisolated static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let fm = FileManager.default
        func visit(_ dir: URL, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            for url in entries {
                if url.pathExtension == "app" {
                    if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id) }
                } else if depth > 0 {
                    visit(url, depth: depth - 1)
                }
            }
        }
        visit(URL(fileURLWithPath: "/Applications"), depth: 2)
        visit(URL(fileURLWithPath: "/System/Applications"), depth: 1)
        return ids
    }
}
