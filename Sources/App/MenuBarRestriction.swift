import Foundation
import os

/// Conceals menu bar icons through MenuBarAgent's assessment-mode restriction
/// (private `MenuBarClientCore` framework, macOS 27).
///
/// Facts this relies on, all observed on macOS 27.0.1:
/// - The restriction is an allow list. Bundle identifiers it names stay
///   visible; every other app's icons are concealed.
/// - System items (Clock, Control Center…) are named by integer identifiers
///   (2 is the Clock, 8 is Control Center). We allow all of them: Apple's
///   items are managed in System Settings > Menu Bar, not here.
/// - The newest active assertion wins, so switching state activates the new
///   one before invalidating the old one: no flash.
/// - When this process exits, even with SIGKILL, MenuBarAgent drops the
///   restriction and every icon comes back.
@MainActor
final class MenuBarRestriction {
    private nonisolated static let log = Logger(subsystem: "com.yohan.betterbar", category: "restriction")
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let systemItemIDs: [NSNumber] = (0..<64).map { NSNumber(value: $0) }

    /// Called when MenuBarAgent rejects an activation.
    var onFailure: ((Error) -> Void)?

    private var current: NSObject?
    private(set) var allowed: Set<String>?

    static let isAvailable: Bool = {
        guard dlopen(frameworkPath, RTLD_NOW) != nil else { return false }
        return NSClassFromString("MBAssessmentModeAssertion") != nil
            && NSClassFromString("MBAssessmentModeConfiguration") != nil
    }()

    var isActive: Bool { current != nil }

    /// Holds a restriction allowing exactly `bundleIDs`.
    func apply(allowing bundleIDs: Set<String>) {
        guard Self.isAvailable else { return }
        guard let next = Self.makeAssertion() , let config = Self.makeConfiguration(bundleIDs: bundleIDs) else {
            Self.log.error("could not build the assertion")
            return
        }
        Self.activate(next, with: config) { [weak self] error in
            guard let error else { return }
            Self.log.error("activation failed: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in self?.onFailure?(error) }
        }
        current.map(Self.invalidate)
        current = next
        allowed = bundleIDs
        Self.log.debug("restriction applied, \(bundleIDs.count) bundles allowed")
    }

    func release() {
        current.map(Self.invalidate)
        current = nil
        allowed = nil
    }

    // MARK: Runtime bridging

    private static func makeConfiguration(bundleIDs: Set<String>) -> NSObject? {
        guard let cls = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        guard let method = class_getInstanceMethod(cls, selector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> NSObject?
        let initialize = unsafeBitCast(method_getImplementation(method), to: Init.self)
        guard let raw = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        return initialize(raw, selector, systemItemIDs as NSArray, bundleIDs.sorted() as NSArray)
    }

    private static func makeAssertion() -> NSObject? {
        (NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type)?.init()
    }

    private static func activate(_ assertion: NSObject, with config: NSObject, completion: @escaping @Sendable (Error?) -> Void) {
        let selector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
        guard let method = class_getInstanceMethod(type(of: assertion), selector) else {
            completion(NSError(domain: "BetterBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "activateWithConfiguration: missing"]))
            return
        }
        typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void) -> Void
        let activate = unsafeBitCast(method_getImplementation(method), to: Activate.self)
        activate(assertion, selector, config) { error in completion(error) }
    }

    private static func invalidate(_ assertion: NSObject) {
        assertion.perform(NSSelectorFromString("invalidate"))
    }
}
