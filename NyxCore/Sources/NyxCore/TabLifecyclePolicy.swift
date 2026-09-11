/// Pure hibernation policy (spec §5.2): only the visible pane(s) plus a
/// small MRU cache of warm tabs keep live webviews; everything else is
/// hibernated (interactionState + snapshot on disk, webview destroyed).
public struct TabLifecyclePolicy {
    public var warmLimit: Int

    public init(warmLimit: Int = 6) {
        self.warmLimit = warmLimit
    }

    /// mruLiveTabs: ids of tabs that currently hold a live webview,
    /// most-recently-used first. Returns the ids to hibernate now.
    /// The selected tab is never evicted regardless of position.
    public func evictionCandidates(mruLiveTabs: [String], selected: String?) -> [String] {
        let evictable = mruLiveTabs.filter { $0 != selected }
        guard evictable.count > warmLimit else { return [] }
        return Array(evictable.dropFirst(warmLimit))
    }
}
