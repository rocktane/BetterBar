import AppKit
import os

/// Puts a brand-new icon in the Visible zone, once.
///
/// macOS 27 adds every new icon at the far left of the status area, left of
/// both separators: in the Always Hidden zone. Its app has no section yet,
/// so it stays drawn while collapsed, but revealing the other sections
/// draws all their icons to its right. The first time an app's icons are
/// seen outside their zone, they are Cmd-dragged right after the separator
/// that starts the Visible zone, the way the user would. After that the
/// app is never moved again: the order of the bar stays the user's.
///
/// Only icons MenuBarAgent currently draws are read and moved: a concealed
/// icon has a stale frame. The drags move the pointer, which is put back;
/// they never start while a button or a modifier is held, and any physical
/// input stops them.
@MainActor
final class IconPlacer {
    private static let log = Logger(subsystem: "com.yohan.betterbar", category: "placer")

    /// Marks the events BetterBar posts, so that its own monitors skip them.
    static let eventTag: Int64 = 0x4242_4152

    private let sections: SectionController
    private let reader: BarReader
    private(set) var isPlacing = false
    private var pending = false

    init(sections: SectionController, reader: BarReader) {
        self.sections = sections
        self.reader = reader
    }

    static func isOwnEvent(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == eventTag
    }

    /// Checks the apps never seen before. Cheap when there are none: the bar
    /// is read only for a new app.
    func placeNewIcons() {
        guard !isPlacing else { pending = true; return }
        guard AXIsProcessTrusted(), !candidates().isEmpty else { return }
        Self.log.debug("new apps: \(self.candidates().sorted().joined(separator: " "), privacy: .public)")
        isPlacing = true
        Task {
            await place()
            isPlacing = false
            if pending { pending = false; placeNewIcons() }
        }
    }

    /// Apps never seen in place, without a section: a section comes from a
    /// Cmd-drop, so the user already placed those.
    private func candidates() -> Set<String> {
        let preferences = sections.preferences
        return Set(sections.apps.map(\.id).filter { preferences.assignments[$0] == nil })
            .subtracting(preferences.placedApps)
    }

    /// The user is not dragging, clicking or holding a modifier that would
    /// change what a synthetic Cmd-drag does.
    private var isIdle: Bool {
        !sections.isHolding && NSEvent.pressedMouseButtons == 0
            && NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    private func place() async {
        guard isIdle else { return retryLater() }
        var items = await reader.settledItems()
        let owners = candidates().intersection(items.map(\.owner))
        Self.log.debug("new apps drawn: \(owners.sorted().joined(separator: " "), privacy: .public) bar: \(items.map { "\($0.owner)@\(Int($0.midX))" }.joined(separator: " "), privacy: .public)")
        guard !owners.isEmpty, BarLayout.separatorMidXs(items).count == 2 else { return }

        // Apps already in their zone (or with a section the user chose) are
        // never moved; only misplaced Visible icons are.
        var stuck: Set<String> = []
        var placed = owners
        startWatchingInput()
        defer { stopWatchingInput() }
        for _ in 0..<30 {
            // A Cmd-drop while we waited placed that app: leave it alone.
            let current = owners.intersection(candidates())
            placed.formIntersection(current.union(sections.preferences.placedApps))
            guard let move = BarLayout.placementMove(items, owners: current, skipping: stuck) else { break }
            guard isIdle, !interrupted, let y = reader.midY[move.itemID] else { return retryLater() }
            Self.log.debug("placing new icon \(move.itemID, privacy: .public) \(move.fromX, privacy: .public) → \(move.toX, privacy: .public)")
            guard await drag(move, y: y) else { return retryLater() }
            let next = await reader.settledItems()
            // An icon that does not move is given up on, not dragged forever.
            if next == items { stuck.insert(move.itemID) }
            items = next
        }
        // One attempt per app: whatever happens next is the user's choice.
        sections.preferences.markPlaced(placed)
    }

    // MARK: User input

    private var inputMonitors: [Any] = []
    /// Set by any physical input while placing: the drag stops at once.
    private var interrupted = false
    /// The user pressed the left button during a placement and has not
    /// released it: their own release ends the drag, never a synthetic one.
    private var userHoldsButton = false

    private func startWatchingInput() {
        interrupted = false
        userHoldsButton = false
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .mouseMoved,
                                           .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard !Self.isOwnEvent(event) else { return }
            let type = event.type
            MainActor.assumeIsolated {
                guard let self else { return }
                self.interrupted = true
                if type == .leftMouseDown { self.userHoldsButton = true }
                if type == .leftMouseUp { self.userHoldsButton = false }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { inputMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) { inputMonitors.append(local) }
    }

    private func stopWatchingInput() {
        inputMonitors.forEach(NSEvent.removeMonitor)
        inputMonitors.removeAll()
    }

    /// The user was busy: look again in a moment.
    private func retryLater() {
        Self.log.debug("busy: placing later")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.placeNewIcons()
        }
    }

    /// A Cmd-drag from the icon's centre to `move.toX`, in small steps so
    /// that MenuBarAgent sees every neighbour being passed. Any physical
    /// input stops it: before the press nothing is posted, during the drag
    /// the button is released where it is. The pointer is put back unless
    /// the user moved it. Returns whether the drag ran to its end.
    private func drag(_ move: BarMove, y: Double) async -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        let saved = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, x: Double, command: Bool = true) {
            post(type, at: CGPoint(x: x, y: y), command: command)
        }
        func post(_ type: CGEventType, at point: CGPoint, command: Bool = true) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left)
            else { return }
            event.flags = command ? .maskCommand : []
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.post(tap: .cghidEventTap)
        }
        func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func restorePointer() { if !interrupted, let saved { CGWarpMouseCursorPosition(saved) } }

        post(.mouseMoved, x: move.fromX, command: false)
        await pause(40)
        guard !interrupted, isIdle else { restorePointer(); return false }
        post(.leftMouseDown, x: move.fromX)
        await pause(80)
        let steps = max(8, Int(abs(move.toX - move.fromX) / 8))
        var x = move.fromX
        for step in 1...steps {
            if interrupted { break }
            x = move.fromX + (move.toX - move.fromX) * Double(step) / Double(steps)
            post(.leftMouseDragged, x: x)
            await pause(12)
        }
        if !interrupted { await pause(80) }
        // Interrupted: release where the user has the pointer, never pull
        // it back to the drag's last step, and not at all while the user
        // holds the button: their release ends it.
        if userHoldsButton {
            // Nothing to post.
        } else if interrupted, let here = CGEvent(source: nil)?.location {
            post(.leftMouseUp, at: here)
        } else {
            post(.leftMouseUp, x: x)
        }
        await pause(40)
        restorePointer()
        return !interrupted
    }
}
