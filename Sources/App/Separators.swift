import AppKit

/// BetterBar's two section separators: `Always Hidden ‹ Hidden ‹ Visible`.
///
/// They are real status items so that macOS keeps their place (keyed by
/// bundle ID and autosave name) like any other icon. Outside a Cmd-drag
/// they have zero length: invisible, and no gap on the bar. Their frames
/// stay readable through Accessibility, so they bound the zones at all
/// times. Newly created, macOS puts them left of every icon; `Arranger`
/// then moves icons of Visible apps to their right.
@MainActor
final class Separators {
    private let items: [NSStatusItem]

    init() {
        items = ["BetterBar.Hidden", "BetterBar.AlwaysHidden"].map { name in
            let item = NSStatusBar.system.statusItem(withLength: 0)
            item.autosaveName = name
            item.button?.setAccessibilityLabel("Séparateur BetterBar")
            return item
        }
    }

    func show(_ visible: Bool, style: SeparatorStyle = .chevron) {
        for item in items {
            item.length = visible ? (style == .space ? 16 : NSStatusItem.variableLength) : 0
            item.button?.image = visible ? Self.glyph(for: style) : nil
        }
    }

    private static func glyph(for style: SeparatorStyle) -> NSImage? {
        let symbol: String
        switch style {
        case .chevron: symbol = "chevron.compact.left"
        case .dot: symbol = "circle.fill"
        case .space: return nil
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Séparateur")
        let sized = image?.withSymbolConfiguration(.init(pointSize: style == .dot ? 5 : 13, weight: .medium))
        sized?.isTemplate = true
        return sized
    }
}
