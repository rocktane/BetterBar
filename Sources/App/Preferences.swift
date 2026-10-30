import Foundation
import Observation

enum SeparatorStyle: String, CaseIterable {
    case chevron, dot, space
}

/// Persisted user choices. Deliberately small: section per app, the
/// auto-hide delay, and the names of apps seen before so the list can show
/// apps that are not running.
@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults

    private(set) var assignments: [String: BarSection]
    private(set) var rememberedNames: [String: String]
    var autoHideEnabled: Bool { didSet { defaults.set(autoHideEnabled, forKey: Keys.autoHideEnabled) } }
    var autoHideDelay: Double { didSet { defaults.set(autoHideDelay, forKey: Keys.autoHideDelay) } }

    var separatorStyle: SeparatorStyle {
        didSet { defaults.set(separatorStyle.rawValue, forKey: Keys.separatorStyle) }
    }

    /// nil when auto-hide is off.
    var effectiveAutoHideDelay: TimeInterval? { autoHideEnabled ? max(1, autoHideDelay) : nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        separatorStyle = SeparatorStyle(rawValue: defaults.string(forKey: Keys.separatorStyle) ?? "") ?? .chevron
        let raw = defaults.dictionary(forKey: Keys.assignments) as? [String: String] ?? [:]
        assignments = raw.compactMapValues(BarSection.init(rawValue:))
        rememberedNames = defaults.dictionary(forKey: Keys.names) as? [String: String] ?? [:]
        autoHideEnabled = defaults.object(forKey: Keys.autoHideEnabled) as? Bool ?? true
        autoHideDelay = defaults.object(forKey: Keys.autoHideDelay) as? Double ?? 5
    }

    func section(for key: String) -> BarSection { assignments[key] ?? .visible }

    func setSection(_ section: BarSection, for app: MenuBarApp) {
        if section == .visible {
            assignments[app.id] = nil
        } else {
            assignments[app.id] = section
            rememberedNames[app.id] = app.name
        }
        save()
    }

    private func save() {
        defaults.set(assignments.mapValues(\.rawValue), forKey: Keys.assignments)
        defaults.set(rememberedNames, forKey: Keys.names)
    }

    private enum Keys {
        static let separatorStyle = "separatorStyle"
        static let assignments = "assignments"
        static let names = "rememberedNames"
        static let autoHideEnabled = "autoHideEnabled"
        static let autoHideDelay = "autoHideDelay"
    }
}
