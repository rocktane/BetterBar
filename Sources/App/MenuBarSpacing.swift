import Foundation
import Observation

/// System-wide AppKit preferences, loaded by each status-item owner at launch.
/// Verified on macOS 27.0.1: existing items keep their geometry after a write;
/// newly launched owners pick up the updated spacing.
/// Opening Settings only reads them; writes happen on Apply or Reset.
@MainActor
@Observable
final class MenuBarSpacing {
    static let appleValue = 16.0
    // Keep the Apple default exactly at the midpoint of the slider.
    static let range = 0.0...(2 * appleValue)

    var value: Double
    private(set) var hasOverride: Bool
    private var appliedValue: Double
    private let domain: CFString

    private static let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
    private static let hosts = [kCFPreferencesCurrentHost, kCFPreferencesAnyHost]

    var hasChanges: Bool { value != appliedValue }

    /// Tests supply a dedicated domain so they never change global preferences.
    init(domain: CFString = kCFPreferencesAnyApplication) {
        self.domain = domain
        let values = Self.snapshot(domain: domain)
        hasOverride = values.contains { !$0.isEmpty }
        let current = values.compactMap { $0[Self.keys[0]] as? NSNumber }.first?.doubleValue ?? Self.appleValue
        value = min(Self.range.upperBound, max(Self.range.lowerBound, current))
        appliedValue = current
    }

    func apply() throws {
        let selected = min(Self.range.upperBound, max(Self.range.lowerBound, value.rounded()))
        if selected == Self.appleValue {
            try reset()
        } else {
            try write(value: Int(selected))
            value = selected
            appliedValue = selected
            hasOverride = true
        }
    }

    func reset() throws {
        try write(value: nil)
        value = Self.appleValue
        appliedValue = value
        hasOverride = false
    }

    private static func snapshot(domain: CFString) -> [[String: Any]] {
        hosts.map { host in
            var values: [String: Any] = [:]
            for key in keys {
                values[key] = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, host)
            }
            return values
        }
    }

    private func write(value: Int?) throws {
        let original = Self.snapshot(domain: domain)
        // Custom values use Ice's current-host scope. Reset also removes older
        // all-host overrides so AppKit can fall back to Apple's defaults.
        let hosts = value == nil ? Self.hosts : [Self.hosts[0]]
        for host in hosts {
            for key in Self.keys {
                CFPreferencesSetValue(key as CFString, value.map { NSNumber(value: $0) }, domain, kCFPreferencesCurrentUser, host)
            }
        }
        var succeeded = true
        for host in hosts {
            if !CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, host) { succeeded = false }
        }
        guard succeeded else {
            for (host, values) in zip(Self.hosts, original) {
                for key in Self.keys {
                    CFPreferencesSetValue(key as CFString, values[key] as CFPropertyList?, domain, kCFPreferencesCurrentUser, host)
                }
                CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, host)
            }
            throw WriteError()
        }
    }

    private struct WriteError: LocalizedError {
        var errorDescription: String? { "Impossible d’enregistrer l’espacement. Réessaie." }
    }
}
