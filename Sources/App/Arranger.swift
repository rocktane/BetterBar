import AppKit
import os

/// Keeps the bar in order, `Always Hidden ‹ Hidden ‹ Visible`, by
/// Cmd-dragging misplaced icons next to the separator that bounds their
/// zone, the way the user would.
///
/// Only icons MenuBarAgent currently draws are read and moved: a concealed
/// icon has a stale frame, and is put in place the next time it is revealed.
/// The drags move the pointer, so they only run while the user's attention
/// is on the bar (a drop, launch) and never while a button is held.
@MainActor
final class Arranger {
    private static let log = Logger(subsystem: "com.yohan.betterbar", category: "arranger")

    /// Marks the events BetterBar posts, so that its own monitors skip them.
    static let eventTag: Int64 = 0x4242_4152

    private let sections: SectionController
    private(set) var isArranging = false

    init(sections: SectionController) {
        self.sections = sections
    }

    static func isOwnEvent(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == eventTag
    }

    /// Reads the bar once it has stopped moving: MenuBarAgent takes a few
    /// hundred milliseconds to settle after a reveal or a drag.
    func settledItems() async -> [BarItem] {
        await settledScan().items
    }

    /// Moves every displayed icon into its app's zone.
    func arrange() async {
        guard !isArranging, AXIsProcessTrusted() else { return }
        isArranging = true
        defer { isArranging = false }

        let revealState = sections.state
        let holding = sections.isHolding
        var scan = await settledScan()
        guard sections.state == revealState, sections.isHolding == holding else { return }
        let misplaced = BarLayout.misplaced(scan.items).count
        Self.log.debug("bar: \(scan.items.map { "\($0.owner)@\(Int($0.midX))" }.joined(separator: " "), privacy: .public)")
        guard misplaced > 0 else { return }
        Self.log.debug("arranging \(misplaced, privacy: .public) misplaced icon(s)")

        // An icon that does not move (Apple's fixed items, a refused drop)
        // is given up on rather than dragged forever.
        var stuck: Set<String> = []
        for _ in 0..<min(misplaced * 2 + 2, 30) {
            guard sections.state == revealState, sections.isHolding == holding,
                  NSEvent.pressedMouseButtons == 0,
                  let move = BarLayout.nextMove(scan.items, skipping: stuck),
                  let y = scan.midY[move.itemID]
            else { break }
            await drag(move, y: y)
            let next = await settledScan()
            if next.items == scan.items { stuck.insert(move.itemID) }
            scan = next
        }
        let left = BarLayout.misplaced(scan.items).count
        if left > 0 { Self.log.error("\(left, privacy: .public) icon(s) could not be put in their section") }
    }

    // MARK: Reading the bar

    private struct Scan: Equatable {
        var items: [BarItem] = []
        var midY: [String: Double] = [:]
    }

    private func settledScan() async -> Scan {
        // MenuBarAgent applies a restriction change or a drop only after a
        // while; until then two reads agree on the old layout.
        try? await Task.sleep(for: .milliseconds(500))
        var previous: Scan?
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(120))
            let current = await scan()
            if current == previous { return current }
            previous = current
        }
        return previous ?? Scan()
    }

    private func scan() async -> Scan {
        let raw = await Task.detached(priority: .userInitiated) { Inventory.statusItems() }.value
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result = Scan()
        for status in raw {
            guard let process = NSRunningApplication(processIdentifier: status.pid) else { continue }
            let key = Self.key(of: process)
            let kind: BarItem.Kind
            if status.pid == ownPID {
                kind = .separator
            } else if Self.isApple(process) {
                kind = .fixed
            } else {
                guard sections.isDisplayed(process) else { continue }
                kind = .icon(sections.preferences.section(for: key))
            }
            let id = "\(status.pid):\(status.index)"
            result.items.append(BarItem(id: id, owner: key, kind: kind,
                                        minX: Double(status.frame.minX), maxX: Double(status.frame.maxX)))
            result.midY[id] = Double(status.frame.midY)
        }
        result.items.sort { $0.minX < $1.minX }
        return result
    }

    /// Apple's own hosts (Clock, Control Center…): never concealed, never
    /// moved, managed in System Settings > Menu Bar.
    static func isApple(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, SystemHosts.bundleIDs.contains(id) { return true }
        return app.bundleURL?.path.hasPrefix("/System/Library/CoreServices/") == true
    }

    static func key(of app: NSRunningApplication) -> String {
        AppIdentity.key(bundleID: app.bundleIdentifier, executableName: app.executableURL?.lastPathComponent ?? "")
    }

    // MARK: Moving an icon

    /// A Cmd-drag from the icon's centre to `move.toX`, in small steps so
    /// that MenuBarAgent sees every neighbour being passed. The pointer is
    /// put back where it was.
    private func drag(_ move: BarMove, y: Double) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        let saved = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, x: Double, command: Bool = true) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
            else { return }
            event.flags = command ? .maskCommand : []
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.post(tap: .cghidEventTap)
        }
        func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        Self.log.debug("drag \(move.itemID, privacy: .public) \(move.fromX, privacy: .public) → \(move.toX, privacy: .public)")
        post(.mouseMoved, x: move.fromX, command: false)
        await pause(40)
        post(.leftMouseDown, x: move.fromX)
        await pause(80)
        let steps = max(8, Int(abs(move.toX - move.fromX) / 8))
        for step in 1...steps {
            post(.leftMouseDragged, x: move.fromX + (move.toX - move.fromX) * Double(step) / Double(steps))
            await pause(12)
        }
        await pause(80)
        post(.leftMouseUp, x: move.toX)
        await pause(40)
        if let saved { CGWarpMouseCursorPosition(saved) }
    }
}
