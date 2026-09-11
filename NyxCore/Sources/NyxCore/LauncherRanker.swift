// NyxCore is a plain Swift/Foundation module: it never imports AppKit,
// SwiftUI, or WebKit. Keep UI- and WebKit-facing code in the app target.

import Foundation

/// A snapshot of an open tab, as the launcher needs it to offer a
/// "switch to tab" result. Deliberately decoupled from any app-side tab
/// model — NyxCore stays Foundation-only.
public struct LauncherTabInfo: Equatable {
    public var id: String
    public var title: String
    public var url: String

    public init(id: String, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// Chrome-level actions the launcher can offer alongside navigation
/// results. `rawValue` doubles as the display name matched against the
/// query, so its cases read as menu-style command labels.
public enum LauncherCommand: String, CaseIterable, Equatable {
    case newTab = "New Tab"
    case splitWithNextTab = "Split with Next Tab"
    case breakUpSplit = "Break Up Split"
    case closeOtherTabs = "Close Other Tabs"
    case newSpace = "New Space"
}

/// One row the launcher can present, already resolved to the action it
/// performs when chosen.
public enum LauncherResult: Equatable {
    case switchToTab(LauncherTabInfo)
    case openURL(URL)               // AddressParser-derived
    case searchWeb(String)          // DuckDuckGo fallthrough
    case history(HistoryEntry)
    case command(LauncherCommand)
}

/// Pure ranking/merging of launcher result sources. Takes already-fetched
/// candidates (open tabs, store-ranked history, the static command list)
/// and produces the ordered, deduped, limit-bounded list the launcher UI
/// renders. No I/O, no AppKit — a plain function of its inputs.
public struct LauncherRanker {
    public init() {}

    /// - Empty query: open tabs (MRU order as given) followed by recent
    ///   history, limit-bounded. No commands, no openURL/searchWeb.
    /// - Non-empty query: tab matches (title/url substring, prefix-boosted),
    ///   then a single `openURL` when the query parses to a real
    ///   destination (see `searchFallbackHost` below), then history matches
    ///   (already store-ranked — passed through in given order, not
    ///   re-filtered or re-sorted here), then command matches (name
    ///   substring), always followed by a trailing `searchWeb`. Truncation
    ///   reserves the last slot for `searchWeb` so it survives any `limit`.
    ///
    /// Dedup — CONVERT, not drop: a history entry whose `url` equals an
    /// open tab's `url` (compared case-insensitively) is replaced by
    /// `.switchToTab(thatTab)` in the history entry's ranked position,
    /// *unless* that tab already appears among the tab matches already
    /// emitted above (or was already converted from an earlier history
    /// entry with the same url) — in that case the history entry is
    /// dropped instead, so the tab is never shown twice. Dropping the
    /// history entry outright (the earlier behavior) could make a result
    /// vanish entirely: history search can match a tab's url on richer
    /// text (title, full url) than the tab-match substring check does, so
    /// a tab that doesn't itself match the query could still be the right
    /// thing to show — as a tab switch, not a dead history entry. Applied
    /// before truncation, for both the empty- and non-empty-query shapes;
    /// for an empty query every open tab is already emitted, so any
    /// matching history entry there is always the "already shown" case
    /// and is simply dropped.
    public func results(query: String,
                        openTabs: [LauncherTabInfo],
                        history: [HistoryEntry],
                        commands: [LauncherCommand],
                        limit: Int) -> [LauncherResult] {
        guard limit > 0 else { return [] }

        // First tab wins on a url collision among open tabs themselves —
        // an edge case the contract doesn't specify further.
        var tabsByLowerURL: [String: LauncherTabInfo] = [:]
        for tab in openTabs where tabsByLowerURL[tab.url.lowercased()] == nil {
            tabsByLowerURL[tab.url.lowercased()] = tab
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let alreadyShown = Set(openTabs.map { $0.url.lowercased() })
            let historyResults = mergedHistoryResults(history, tabsByLowerURL: tabsByLowerURL,
                                                       alreadyShownTabURLs: alreadyShown)
            let combined = openTabs.map(LauncherResult.switchToTab) + historyResults
            return Array(combined.prefix(limit))
        }

        let lowerQuery = trimmed.lowercased()

        let tabMatches = rankedTabMatches(openTabs, lowerQuery: lowerQuery)
        let alreadyShown = Set(tabMatches.map { $0.url.lowercased() })
        let historyResults = mergedHistoryResults(history, tabsByLowerURL: tabsByLowerURL,
                                                   alreadyShownTabURLs: alreadyShown)

        var out: [LauncherResult] = tabMatches.map(LauncherResult.switchToTab)
        if let openURLResult = openURLResult(for: trimmed) {
            out.append(openURLResult)
        }
        out.append(contentsOf: historyResults)
        out.append(contentsOf: commands
            .filter { $0.rawValue.lowercased().contains(lowerQuery) }
            .map(LauncherResult.command))

        // Reserve the trailing slot for searchWeb so it's never truncated away.
        let truncated = out.prefix(max(limit - 1, 0))
        return Array(truncated) + [.searchWeb(trimmed)]
    }

    /// Converts each history entry whose `url` matches an open tab into
    /// `.switchToTab` in place, dropping it instead when that tab is
    /// already shown (either because it's among `alreadyShownTabURLs`, or
    /// because an earlier history entry in this same list already
    /// converted to it — tracked via a growing local copy so two history
    /// entries that happen to share a url can't both surface the same
    /// tab). Entries with no matching open tab pass through unchanged.
    private func mergedHistoryResults(_ history: [HistoryEntry],
                                      tabsByLowerURL: [String: LauncherTabInfo],
                                      alreadyShownTabURLs: Set<String>) -> [LauncherResult] {
        var shown = alreadyShownTabURLs
        return history.compactMap { entry in
            let lowerURL = entry.url.lowercased()
            guard let matchingTab = tabsByLowerURL[lowerURL] else {
                return .history(entry)
            }
            guard !shown.contains(lowerURL) else { return nil }
            shown.insert(lowerURL)
            return .switchToTab(matchingTab)
        }
    }

    /// Tabs whose title or url contains `lowerQuery`, ordered with a
    /// prefix boost: a title-prefix match ranks above a url-prefix match,
    /// which ranks above a title-substring match, which ranks above a
    /// url-substring match. Ties (including tabs that don't match at all
    /// scoring band) preserve the input's relative (MRU) order — the sort
    /// key pairs the match rank with the original index so it can't
    /// depend on the standard library's sort stability.
    private func rankedTabMatches(_ tabs: [LauncherTabInfo], lowerQuery: String) -> [LauncherTabInfo] {
        let scored: [(rank: Int, index: Int, tab: LauncherTabInfo)] = tabs.enumerated().compactMap { index, tab in
            let title = tab.title.lowercased()
            let url = tab.url.lowercased()
            let rank: Int
            if title.hasPrefix(lowerQuery) { rank = 0 }
            else if url.hasPrefix(lowerQuery) { rank = 1 }
            else if title.contains(lowerQuery) { rank = 2 }
            else if url.contains(lowerQuery) { rank = 3 }
            else { return nil }
            return (rank, index, tab)
        }
        return scored
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.tab)
    }

    /// The launcher's known search fallback host: `AddressParser` routes
    /// anything it can't resolve to a real destination through a DuckDuckGo
    /// query URL, so a parse landing on this host is the `searchWeb` case,
    /// not a navigable `openURL`.
    ///
    /// Discrimination approach (chosen over re-implementing AddressParser's
    /// "looks like a URL" heuristic): compare the parsed URL's host against
    /// this known search host rather than duplicating that parsing logic
    /// here. This trades away precision on a wider scope than just the
    /// literal bare-domain "duckduckgo.com" query: *any* query that
    /// AddressParser resolves to a `duckduckgo.com` host loses `openURL`,
    /// including paths/queries under that host that are genuine
    /// navigable destinations via the bare-host rule (e.g.
    /// "duckduckgo.com/settings" resolves to a real
    /// `https://duckduckgo.com/settings` page, not a search, but is still
    /// treated as the search-fallback case here and withholds `openURL`).
    /// Accepted in favor of not having two independently-maintained copies
    /// of "is this a search URL" that could drift apart; pinned by
    /// `LauncherRankerTests.testAnyQueryParsingToDuckDuckGoHostHasNoOpenURL`.
    private static let searchFallbackHost = "duckduckgo.com"

    private func openURLResult(for trimmedQuery: String) -> LauncherResult? {
        guard let url = AddressParser.destinationURL(for: trimmedQuery) else { return nil }
        guard url.host?.lowercased() != Self.searchFallbackHost else { return nil }
        return .openURL(url)
    }
}
