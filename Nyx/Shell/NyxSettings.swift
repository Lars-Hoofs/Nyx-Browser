import Foundation

/// M5 Task 6: the tiny persisted knob behind the View menu's "Block Ads"
/// item. A plain UserDefaults-backed struct — no notification/observation
/// machinery, because every mutator in this codebase (the coordinator's
/// toggle action) re-evaluates and reloads synchronously right after
/// writing, so nothing else needs to react to a change.
///
/// `defaults` is injectable so unit tests can point at an isolated suite
/// instead of polluting the shared `.standard` domain; production call
/// sites use the default argument.
struct NyxSettings {
    private static let adblockEnabledKey = "nyx.adblock.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Global adblock toggle. Defaults to `true` (blocking ON) when never
    /// set — matches the site-override default (M5 spec: blocking ON
    /// everywhere until the user opts out, per host or globally).
    var adblockEnabled: Bool {
        get { defaults.object(forKey: Self.adblockEnabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.adblockEnabledKey) }
    }
}
