import Foundation

/// One item of the status area, read through Accessibility.
struct BarItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// One of BetterBar's two separators.
        case separator
        /// An icon, with the section its app belongs to.
        case icon(BarSection)
        /// One of Apple's items: never concealed, never assigned a section.
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

/// The zones a Cmd-drop can land in, left to right:
/// `Always Hidden ‹ separator ‹ Hidden ‹ separator ‹ Visible`.
///
/// Assignments are the only source of truth. The bar is read to place a
/// drop, and to put a brand-new icon in the Visible zone once (macOS adds
/// it at the far left); otherwise BetterBar never moves an icon. Which
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

    /// The next drag putting a newly seen Visible icon of one of `owners`
    /// right after the separator that starts the Visible zone, or nil when
    /// there is none left. Only Visible icons are moved: an app that already
    /// has a section was placed by the user.
    ///
    /// Observed on macOS 27: while an icon is dragged, it passes a neighbour
    /// once the pointer crosses that neighbour's centre, measured where the
    /// neighbour stood before the drag. So releasing halfway between two
    /// centres inserts the icon between those two items. Moving the
    /// rightmost icon first keeps an app's icons in their order.
    static func placementMove(_ items: [BarItem], owners: Set<String>, skipping skipped: Set<String> = []) -> BarMove? {
        let ordered = items.sorted { $0.midX < $1.midX }
        guard let right = ordered.last(where: { $0.kind == .separator }),
              ordered.filter({ $0.kind == .separator }).count == 2
        else { return nil }
        let seps = separatorMidXs(ordered)
        let misplaced = ordered.filter { item in
            owners.contains(item.owner) && item.kind == .icon(.visible) && !skipped.contains(item.id)
                && zone(atX: item.midX, separatorMidXs: seps) != .visible
        }
        guard let item = misplaced.last else { return nil }
        let others = ordered.filter { $0.id != item.id }
        let toX: Double
        if let next = others.first(where: { $0.midX > right.midX }) {
            toX = (right.midX + next.midX) / 2
        } else {
            toX = right.midX + edgeMargin
        }
        return BarMove(itemID: item.id, fromX: item.midX, toX: toX)
    }

    /// Past the last item, any point beyond its centre will do.
    private static let edgeMargin: Double = 8

    /// A press only becomes a drag past this distance, so a Cmd-click
    /// reveals nothing.
    static let dragThreshold: Double = 4
}
