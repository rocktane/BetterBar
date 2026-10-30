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

/// The zones a Cmd-drop can land in, left to right:
/// `Always Hidden ‹ separator ‹ Hidden ‹ separator ‹ Visible`.
///
/// Assignments are the only source of truth. The bar is read only to place
/// a drop; BetterBar never moves an icon. Which separator is which does not
/// matter: only their order on the bar.
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

    /// A press only becomes a drag past this distance, so a Cmd-click
    /// reveals nothing.
    static let dragThreshold: Double = 4
}
