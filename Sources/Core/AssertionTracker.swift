import Foundation

/// Tracks MenuBarAgent restriction assertions by number, so that the bar is
/// never left without a restriction while a newer one is activating or after
/// one is rejected: an unrestricted bar reveals Always Hidden.
///
/// It decides which assertions to invalidate; the caller performs it.
struct AssertionTracker: Sendable {
    /// The latest requested assertion.
    private(set) var current: Int?
    private(set) var allowed: Set<String>?
    /// The last assertion MenuBarAgent confirmed. It stays active until a
    /// newer one is confirmed.
    private(set) var confirmed: Int?
    private var confirmedAllowed: Set<String>?
    /// Requested assertions superseded before being confirmed.
    private(set) var pending: [Int] = []

    var isActive: Bool { current != nil }

    /// Assertions that may currently be held by MenuBarAgent.
    var live: Set<Int> { Set([current, confirmed].compactMap { $0 } + pending) }

    mutating func requested(_ id: Int, allowing bundleIDs: Set<String>) {
        if let current, current != confirmed { pending.append(current) }
        current = id
        allowed = bundleIDs
    }

    /// Returns the assertions to invalidate and whether the latest request
    /// failed (to retry it).
    mutating func activated(_ id: Int, succeeded: Bool) -> (invalidate: [Int], latestFailed: Bool) {
        guard live.contains(id) else { return ([], false) }
        if !succeeded {
            pending.removeAll { $0 == id }
            guard id == current else { return ([id], false) }
            // Keep the last confirmed restriction; report the latest as not applied.
            current = confirmed
            allowed = confirmedAllowed
            return ([id], true)
        }
        guard id == current else {
            // Superseded: keep it only while nothing is confirmed, so the bar
            // stays restricted until the latest lands.
            guard confirmed != nil || current == nil else { return ([], false) }
            pending.removeAll { $0 == id }
            return ([id], false)
        }
        // The newest active assertion wins: drop the older ones only now.
        let dropped = [confirmed].compactMap { $0 } + pending
        pending.removeAll()
        confirmed = id
        confirmedAllowed = allowed
        return (dropped, false)
    }

    /// Returns every assertion to invalidate.
    mutating func release() -> [Int] {
        let all = Array(live)
        self = AssertionTracker()
        return all
    }
}
