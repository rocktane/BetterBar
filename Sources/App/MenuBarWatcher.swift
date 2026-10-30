import AppKit
import os

/// Global input around the menu bar: clicks on empty space, Cmd-drags of
/// icons, and the auto-hide clock. BetterBar never moves an icon itself: a
/// Cmd-drop only tells which section the user chose for the app.
@MainActor
final class MenuBarWatcher {
    private static let log = Logger(subsystem: "com.yohan.betterbar", category: "input")
    private let sections: SectionController
    private let preferences: Preferences
    private let separators = Separators()
    private let reader: BarReader
    private let showContextMenu: (NSPoint) -> Void

    private var monitors: [Any] = []
    private var clock = AutoHideClock(delay: nil)
    private var timer: Timer?
    private var lastHandledEvent: (TimeInterval, NSEvent.EventType)?
    private var pendingMenu: DispatchWorkItem?
    private var clickTask: Task<Void, Never>?
    private var lastBusy = false

    /// A Cmd-press on an icon, which becomes a drag once the pointer moves.
    private struct Press { var pid: pid_t?; let origin: NSPoint; var dragging = false }
    private var pressGeneration = 0
    private var press: Press?
    /// From the first Cmd-drag until Command is released: everything stays
    /// revealed and the separators drawn, so that several icons can be
    /// dropped in a row.
    private var cmdDragSession = false
    private var dropsInFlight = 0

    init(sections: SectionController, preferences: Preferences, showContextMenu: @escaping (NSPoint) -> Void) {
        self.sections = sections
        self.preferences = preferences
        self.showContextMenu = showContextMenu
        reader = BarReader(sections: sections)
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        // Clicks on the menu bar while betterbar's Settings is frontmost.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(local) }
        sections.onStateChange = { [weak self] state in self?.stateChanged(state) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        separators.show(false)
        stopClock()
    }

    // MARK: Events

    private func handle(_ event: NSEvent) {
        // Global and local monitors can both see one event.
        if let last = lastHandledEvent, last == (event.timestamp, event.type) { return }
        lastHandledEvent = (event.timestamp, event.type)

        switch event.type {
        case .leftMouseDown, .rightMouseDown: mouseDown(event)
        case .leftMouseDragged: mouseDragged()
        case .leftMouseUp: mouseUp()
        case .flagsChanged: endCmdDragSessionIfDone()
        default: break
        }
    }

    private func mouseDown(_ event: NSEvent) {
        pendingMenu?.cancel()
        press = nil
        pressGeneration += 1
        // Command released while its key-up went unseen.
        endCmdDragSessionIfDone()
        let point = NSEvent.mouseLocation
        guard let probes = MenuBarGeometry.probePoints(for: point) else {
            collapseAfterOutsideClick(at: point)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let generation = pressGeneration

        if flags.contains(.command) {
            guard event.type == .leftMouseDown else { return }
            // Track the press at once; which app owns the icon is resolved
            // in the background and is needed only at the drop.
            press = Press(pid: nil, origin: point)
            Task.detached { [probe = probes[0]] in
                let pid = MenuBarGeometry.iconOwner(at: probe)
                await MainActor.run {
                    guard self.pressGeneration == generation else { return }
                    if pid == nil { self.press = nil } else { self.press?.pid = pid }
                }
            }
            return
        }
        let secondary = event.type == .rightMouseDown || flags.contains(.control)
        let option = flags.contains(.option)
        let clickCount = event.clickCount
        // AX queries can finish out of order. Preserve input order; the
        // controller ignores subsequent presses in a multi-click sequence.
        let previousClick = clickTask
        clickTask = Task {
            await previousClick?.value
            let empty = await Task.detached { MenuBarGeometry.isEmptySpace(probes: probes) }.value
            Self.log.debug("press at \(point.x, privacy: .public) empty=\(empty, privacy: .public)")
            guard empty else { return }
            if secondary {
                // Opening on the same runloop turn lets the mouse-up close it.
                let work = DispatchWorkItem { self.showContextMenu(point) }
                self.pendingMenu = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            } else {
                self.sections.click(option: option, clickCount: clickCount)
            }
        }
    }

    /// A click away from the bar conceals at once, rather than after the
    /// auto-hide delay. A click in a menu or popover opened from a revealed
    /// icon keeps it revealed: concealing the icon would cut its menu off.
    private func collapseAfterOutsideClick(at point: NSPoint) {
        guard sections.state.isRevealing, !sections.isHolding,
              !MenuBarGeometry.isInIconMenu(point)
        else { return }
        Self.log.debug("click outside the bar: collapsing")
        sections.collapse()
    }

    private func mouseDragged() {
        guard var current = press, !current.dragging else { return }
        let point = NSEvent.mouseLocation
        guard hypot(point.x - current.origin.x, point.y - current.origin.y) > BarLayout.dragThreshold else { return }
        current.dragging = true
        press = current
        guard !cmdDragSession else { return }
        cmdDragSession = true
        Self.log.debug("cmd-drag: revealed until Command is released")
        sections.beginHold()
        separators.show(true, style: preferences.separatorStyle)
    }

    private func mouseUp() {
        guard let finished = press else { return }
        press = nil
        guard finished.dragging else { return }
        let dropX = Double(NSEvent.mouseLocation.x)
        dropsInFlight += 1
        Task {
            await self.completeDrop(pid: finished.pid, dropX: dropX)
            self.dropsInFlight -= 1
            self.endCmdDragSessionIfDone()
        }
    }

    /// Reads where the icon actually landed (macOS snaps it to a slot), while
    /// everything is still revealed and the separators are still drawn. No
    /// icon is moved: the app's other icons stay where the user left them.
    private func completeDrop(pid: pid_t?, dropX: Double) async {
        guard let app = pid.flatMap(Self.assignableApp(pid:)),
              let section = BarLayout.droppedSection(await reader.settledItems(), owner: app.id, dropX: dropX)
        else { return }
        sections.setSection(section, for: app)
    }

    /// Conceals again once Command is up and every drop has been read.
    private func endCmdDragSessionIfDone() {
        guard cmdDragSession, dropsInFlight == 0, press?.dragging != true,
              !NSEvent.modifierFlags.contains(.command)
        else { return }
        cmdDragSession = false
        Self.log.debug("cmd-drag: done")
        separators.show(false)
        sections.endHold()
    }

    /// Apple's own hosts (Clock, Control Center…) cannot be concealed.
    private static func assignableApp(pid: pid_t) -> MenuBarApp? {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let process = NSRunningApplication(processIdentifier: pid),
              !BarReader.isApple(process)
        else { return nil }
        let exe = process.executableURL?.lastPathComponent ?? ""
        return MenuBarApp(id: BarReader.key(of: process),
                          bundleID: process.bundleIdentifier, name: process.localizedName ?? exe,
                          bundlePath: process.bundleURL?.path, iconCount: 0)
    }

    // MARK: Auto-hide

    private func stateChanged(_ state: RevealState) {
        guard state.isRevealing else { return stopClock() }
        clock = AutoHideClock(delay: preferences.effectiveAutoHideDelay)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        clock.delay = preferences.effectiveAutoHideDelay
        let pressing = press != nil, inBar = MenuBarGeometry.isInMenuBar(NSEvent.mouseLocation)
        let buttons = NSEvent.pressedMouseButtons != 0, menuOpen = MenuBarGeometry.isIconMenuOpen()
        let busy = pressing || inBar || buttons || menuOpen || sections.isHolding
        if busy != lastBusy {
            lastBusy = busy
            Self.log.debug("auto-hide busy=\(busy, privacy: .public) press=\(pressing, privacy: .public) bar=\(inBar, privacy: .public) buttons=\(buttons, privacy: .public) menu=\(menuOpen, privacy: .public)")
        }
        if clock.tick(busy: busy, now: Date()) {
            Self.log.debug("auto-hide: collapsing")
            sections.collapse()
        }
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }
}
