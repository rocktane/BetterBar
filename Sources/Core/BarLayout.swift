import Foundation

/// One item of the status area, read through Accessibility.
struct BarItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// One of BetterBar's two separators.
        case separator
        /// An icon, with the section its app belongs to.
        case icon(BarSection)
        /// One of Apple's items: never moved (some cannot be, others are
        /// transient indicators), but it takes up a slot.
        case fixed
    }

    /// `pid:index`, stable between two reads of an unchanged bar.
    let id: String
    /// The owning app's assignment key (see `AppIdentity.key`).
    let owner: String
    let kind: Kind
    let minX: Double
    let maxX: Double

    var midX: Double { (minX + maxX) / 2 }
}

/// A Cmd-drag of one icon: press at its centre, release at `toX`.
struct BarMove: Equatable, Sendable {
    let itemID: String
    let fromX: Double
    let toX: Double
}

/// The rule BetterBar enforces, left to right:
/// `Always Hidden ‹ separator ‹ Hidden ‹ separator ‹ Visible`.
///
/// Assignments are the only source of truth. The bar is read to place a
/// drop, then rearranged so that every icon sits in its app's zone. Which
/// separator is which does not matter: only their order on the bar.
enum BarLayout {
    /// The zone a horizontal position falls in, given the separators'
    /// centres; nil unless there are exactly two.
    static func zone(atX x: Double, separatorMidXs: [Double]) -> BarSection? {
        guard separatorMidXs.count == 2 else { return nil }
        let bounds = separatorMidXs.sorted()
        if x < bounds[0] { return .alwaysHidden }
        if x < bounds[1] { return .hidden }
        return .visible
    }

    static func separatorMidXs(_ items: [BarItem]) -> [Double] {
        items.filter { $0.kind == .separator }.map(\.midX).sorted()
    }

    /// Where a Cmd-dragged icon of `owner` landed: the zone of the app's
    /// icon closest to the drop point (an app such as Stats has several).
    static func droppedSection(_ items: [BarItem], owner: String, dropX: Double) -> BarSection? {
        let icons = items.filter { $0.owner == owner && $0.kind != .separator && $0.kind != .fixed }
        guard let icon = icons.min(by: { abs($0.midX - dropX) < abs($1.midX - dropX) }) else { return nil }
        return zone(atX: icon.midX, separatorMidXs: separatorMidXs(items))
    }

    /// Icons outside their app's zone.
    static func misplaced(_ items: [BarItem]) -> [BarItem] {
        let seps = separatorMidXs(items)
        guard seps.count == 2 else { return [] }
        return items.filter { item in
            guard case .icon(let section) = item.kind else { return false }
            return zone(atX: item.midX, separatorMidXs: seps) != section
        }
    }

    /// The next drag towards a consistent bar, or nil when it already is.
    ///
    /// Observed on macOS 27: while an icon is dragged, it passes a neighbour
    /// once the pointer crosses that neighbour's centre, measured where the
    /// neighbour stood before the drag. So releasing halfway between two
    /// centres inserts the icon between those two items.
    ///
    /// Icons go right next to the separator that bounds their zone. Moves to
    /// the right are made from the rightmost icon first and moves to the left
    /// from the leftmost first, so icons keep their relative order.
    static func nextMove(_ items: [BarItem], skipping skipped: Set<String> = []) -> BarMove? {
        let ordered = items.sorted { $0.midX < $1.midX }
        let separators = ordered.filter { $0.kind == .separator }
        guard separators.count == 2 else { return nil }
        let (left, right) = (separators[0], separators[1])

        var rightward: [(BarItem, Double)] = []
        var leftward: [(BarItem, Double)] = []
        for item in misplaced(ordered) where !skipped.contains(item.id) {
            guard case .icon(let section) = item.kind,
                  let current = zone(atX: item.midX, separatorMidXs: [left.midX, right.midX])
            else { continue }
            let others = ordered.filter { $0.id != item.id }
            switch (current, section) {
            case (_, .visible):
                rightward.append((item, after(right, in: others)))
            case (.alwaysHidden, .hidden):
                rightward.append((item, after(left, in: others)))
            case (.visible, .hidden):
                leftward.append((item, before(right, in: others)))
            default: // to Always Hidden
                leftward.append((item, before(left, in: others)))
            }
        }
        let pick = rightward.max { $0.0.midX < $1.0.midX } ?? leftward.min { $0.0.midX < $1.0.midX }
        return pick.map { BarMove(itemID: $0.0.id, fromX: $0.0.midX, toX: $0.1) }
    }

    /// Release point that inserts right after `anchor`.
    private static func after(_ anchor: BarItem, in others: [BarItem]) -> Double {
        guard let next = others.first(where: { $0.midX > anchor.midX }) else { return anchor.midX + edgeMargin }
        return (anchor.midX + next.midX) / 2
    }

    /// Release point that inserts right before `anchor`.
    private static func before(_ anchor: BarItem, in others: [BarItem]) -> Double {
        guard let previous = others.last(where: { $0.midX < anchor.midX }) else { return anchor.midX - edgeMargin }
        return (previous.midX + anchor.midX) / 2
    }

    /// Past the last item, any point beyond its centre will do.
    private static let edgeMargin: Double = 8

    /// A press only becomes a drag past this distance, so a Cmd-click
    /// reveals nothing.
    static let dragThreshold: Double = 4
}
