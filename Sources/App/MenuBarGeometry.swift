import AppKit
import ApplicationServices

/// Menu bar geometry and Accessibility hit-testing.
///
/// Coordinates: Cocoa (bottom-left origin) for `NSScreen`/`NSEvent`,
/// converted to the top-left origin that Accessibility and CoreGraphics use.
@MainActor
enum MenuBarGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let reserved = screen.frame.maxY - screen.visibleFrame.maxY
        if reserved > 4 { return reserved }
        // Menu bar set to hide automatically: fall back to the notch inset
        // or the classic height.
        return max(screen.safeAreaInsets.top, NSStatusBar.system.thickness, 24)
    }

    /// The screen whose menu bar strip contains the Cocoa point, if any.
    static func menuBarScreen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let frame = screen.frame
            return point.x >= frame.minX && point.x < frame.maxX
                && point.y <= frame.maxY && point.y >= frame.maxY - menuBarHeight(of: screen)
        }
    }

    static func isInMenuBar(_ point: NSPoint) -> Bool { menuBarScreen(at: point) != nil }

    /// Accessibility points (top-left origin) to probe for a click at the
    /// Cocoa point: the point itself, then its mirrors on other displays
    /// (macOS 27 reports icon frames for one display only).
    static func probePoints(for point: NSPoint) -> [CGPoint]? {
        guard let screen = menuBarScreen(at: point) else { return nil }
        // At the exact top edge macOS 27 can return AXWindow instead of
        // AXMenuBar. Probe one point inside the bar, keeping x unchanged
        // so menu titles and status icons still veto an empty-space click.
        let probeY = min(point.y, screen.frame.maxY - 1)
        var points = [CGPoint(x: point.x, y: primaryHeight - probeY)]
        for other in NSScreen.screens where other != screen {
            let otherY = primaryHeight - other.frame.maxY + menuBarHeight(of: other) / 2
            let xs = ClickClassifier.mirroredXs(
                x: point.x,
                from: (screen.frame.minX, screen.frame.maxX),
                to: (other.frame.minX, other.frame.maxX)
            )
            points += xs.map { CGPoint(x: $0, y: otherY) }
        }
        return points
    }

    // MARK: Accessibility (blocking: call off the main thread, so that a
    // probe landing on BetterBar's own menu bar can be answered)

    nonisolated static func isEmptySpace(probes: [CGPoint]) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return ClickClassifier.isEmptySpace(probes.map { hit(at: $0) })
    }

    private nonisolated static func element(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    nonisolated static func hit(at point: CGPoint) -> MenuBarHit {
        guard let element = element(at: point) else { return .other }
        switch string(element, kAXRoleAttribute) {
        case "AXMenuBar":
            return .bar
        case "AXMenuBarItem":
            return string(element, kAXSubroleAttribute) == "AXMenuExtra" ? .icon : .appMenu
        default:
            return .other
        }
    }

    /// The process owning the status icon at an Accessibility point, if any.
    nonisolated static func iconOwner(at point: CGPoint) -> pid_t? {
        guard AXIsProcessTrusted(), let element = element(at: point),
              string(element, kAXSubroleAttribute) == "AXMenuExtra"
        else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Whether a menu or popover opened from an icon is on screen: a window
    /// at menu bar level or above, from another app, hanging from the top of
    /// a display. Readable without Screen Recording (no titles needed).
    static func isIconMenuOpen() -> Bool { !iconMenuFrames().isEmpty }

    /// Whether the Cocoa point falls in a menu or popover opened from an icon.
    static func isInIconMenu(_ point: NSPoint) -> Bool {
        let flipped = CGPoint(x: point.x, y: primaryHeight - point.y)
        return iconMenuFrames().contains { $0.contains(flipped) }
    }

    /// Frames (top-left origin) of the menus and popovers opened from icons.
    private static func iconMenuFrames() -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let bars = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY,
                   width: $0.frame.width, height: menuBarHeight(of: $0))
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.filter { isIconMenuWindow($0, ownPID: ownPID, menuBars: bars) }.compactMap { info in
            (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
    }

    static func isIconMenuWindow(_ info: [String: Any], ownPID: pid_t, menuBars: [CGRect]) -> Bool {
        guard let layer = info[kCGWindowLayer as String] as? Int,
              layer >= Int(CGWindowLevelForKey(.mainMenuWindow)), layer < Int(CGWindowLevelForKey(.screenSaverWindow)),
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
              (info[kCGWindowOwnerName as String] as? String) != "Window Server",
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width > 1, bounds.height > 1
        else { return false }
        return menuBars.contains { bar in
            bounds.maxX > bar.minX && bounds.minX < bar.maxX
                && bounds.minY >= bar.maxY - 4 && bounds.minY <= bar.maxY + 16
        }
    }
}
