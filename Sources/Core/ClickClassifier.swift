import Foundation

/// What Accessibility reports under a point of the menu bar.
enum MenuBarHit: Equatable, Sendable {
    /// The frontmost app's menu bar itself, outside any menu title or icon.
    case bar
    /// An app menu title (File, Edit…) or the Apple menu.
    case appMenu
    /// A status icon (third-party or system).
    case icon
    /// Anything else, including an AX failure.
    case other
}

enum ClickClassifier {
    /// A click counts as "empty space" only when every probe agrees.
    ///
    /// On a secondary display macOS 27 draws the same icons but reports
    /// their frames for one display only, so the caller adds probes at the
    /// mirrored positions; any probe landing on something vetoes.
    static func isEmptySpace(_ probes: [MenuBarHit]) -> Bool {
        guard let first = probes.first, first == .bar else { return false }
        return probes.dropFirst().allSatisfy { $0 == .bar || $0 == .other }
    }

    /// Mirrors x from one menu bar to another: icons are right-aligned and
    /// app menus left-aligned, so both alignments are probed.
    static func mirroredXs(x: Double, from source: (minX: Double, maxX: Double), to target: (minX: Double, maxX: Double)) -> [Double] {
        let fromLeft = target.minX + (x - source.minX)
        let fromRight = target.maxX - (source.maxX - x)
        return [fromLeft, fromRight].filter { $0 >= target.minX && $0 < target.maxX }
    }
}
