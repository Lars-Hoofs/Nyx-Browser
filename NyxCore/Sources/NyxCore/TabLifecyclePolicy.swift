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
    /// Pinned tabs (every visible pane — the whole split group) are never
    /// evicted; of the rest, keep the `warmLimit` most recent.
    public func evictionCandidates(mruLiveTabs: [String], pinned: Set<String>) -> [String] {
        let evictable = mruLiveTabs.filter { !pinned.contains($0) }
        guard evictable.count > warmLimit else { return [] }
        return Array(evictable.dropFirst(warmLimit))
    }
}
