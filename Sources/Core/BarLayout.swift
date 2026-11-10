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
    /// in the Visible zone, or nil when there is none left. Only Visible
    /// icons are moved: an app that already has a section was placed by the
    /// user.
    ///
    /// With both separators drawn, the icon goes right after them. While a
    /// restriction conceals them (their frames are then stale), it goes
    /// right after the first drawn icon that is plainly in the Visible zone:
    /// a Visible app's icon right of every drawn icon of a concealable
    /// section. MenuBarAgent then records the new icon right of that one, so
    /// right of the concealed separator.
    ///
    /// Observed on macOS 27: while an icon is dragged, it passes a neighbour
    /// once the pointer crosses that neighbour's centre, measured where the
    /// neighbour stood before the drag. So releasing halfway between two
    /// centres inserts the icon between those two items. Moving the
    /// rightmost icon first keeps an app's icons in their order.
    static func placementMove(_ items: [BarItem], owners: Set<String>, skipping skipped: Set<String> = []) -> BarMove? {
        guard let layout = misplaced(items, owners: owners),
              let item = layout.icons.last(where: { !skipped.contains($0.id) })
        else { return nil }
        let others = items.sorted { $0.midX < $1.midX }.filter { $0.id != item.id }
        let toX: Double
        if let next = others.first(where: { $0.midX > layout.anchor.midX }) {
            toX = (layout.anchor.midX + next.midX) / 2
        } else {
            toX = layout.anchor.midX + edgeMargin
        }
        return BarMove(itemID: item.id, fromX: item.midX, toX: toX)
    }

    /// The Visible icons of `owners` outside the Visible zone, left to right,
    /// and the item they go right after; nil when the bar cannot tell (one
    /// separator, or separators concealed and no Visible icon to go by).
    static func misplaced(_ items: [BarItem], owners: Set<String>) -> (anchor: BarItem, icons: [BarItem])? {
        let ordered = items.sorted { $0.midX < $1.midX }
        let movable = ordered.filter { owners.contains($0.owner) && $0.kind == .icon(.visible) }
        let seps = separatorMidXs(ordered)
        if seps.count == 2, let right = ordered.last(where: { $0.kind == .separator }) {
            return (right, movable.filter { zone(atX: $0.midX, separatorMidXs: seps) != .visible })
        }
        guard seps.isEmpty else { return nil }
        let concealable = ordered.filter { if case .icon(let section) = $0.kind { section != .visible } else { false } }
        let edge = concealable.last?.midX ?? -.infinity
        guard let first = ordered.first(where: {
            $0.kind == .icon(.visible) && !owners.contains($0.owner) && $0.midX > edge
        }) else { return nil }
        return (first, movable.filter { $0.midX < first.midX })
    }

    /// Past the last item, any point beyond its centre will do.
    private static let edgeMargin: Double = 8

    /// A press only becomes a drag past this distance, so a Cmd-click
    /// reveals nothing.
    static let dragThreshold: Double = 4
}
