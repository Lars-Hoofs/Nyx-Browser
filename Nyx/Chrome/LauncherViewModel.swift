import Foundation
import Observation
import NyxCore

/// What the coordinator should DO for a chosen launcher result — the view
/// model resolves a `LauncherResult` down to one of these, and
/// `NyxWindowCoordinator` executes it (dismissing the panel first). Kept
/// separate from `LauncherResult` on purpose: results are what the list
/// SHOWS (rich enough to render a row), actions are the minimal
/// instruction the coordinator needs.
enum LauncherAction: Equatable {
    case switchToTab(String)
    case navigate(URL, newTab: Bool)
    case run(LauncherCommand)
}

/// State + behavior behind the ⌘K launcher (spec §5.5): owns the query,
/// the ranked results, and the keyboard selection. Everything recomputes
/// SYNCHRONOUSLY on each query edit — no async, no debounce: open tabs
/// come straight from `TabManager`, history is one indexed FTS query with
/// a small limit, and the ranker is a pure function, so a recompute is
/// well under the brief's 10 ms budget at realistic history sizes.
///
/// A fresh instance is built per panel show (Spotlight-style reset —
/// `LauncherPanelController`'s contentProvider re-runs on every show), so
/// this class never needs a `reset()`.
@MainActor
@Observable
final class LauncherViewModel {
    var query: String = "" {
        didSet { recompute() }
    }
    private(set) var results: [LauncherResult] = []
    /// The keyboard-highlighted row. The view may also set it directly
    /// (mouse click on a row); it is clamped by `moveSelection` and reset
    /// to the top on every recompute.
    var selectedIndex: Int = 0

    /// Rows the launcher shows at most. LauncherView's fixed results-area
    /// height is sized to exactly this many rows — keep the two in sync.
    static let resultLimit = 10
    /// History candidates fetched per recompute (per the task brief).
    /// Slightly above `resultLimit` so history can still fill the list
    /// after dedupe against open tabs.
    private static let historyLimit = 12

    @ObservationIgnored private let manager: TabManager
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let ranker: LauncherRanker
    /// Re-evaluated on EVERY recompute (not captured once): command
    /// availability is coordinator state (canSplit, isInSplit, …) that
    /// can change while the panel is up — e.g. a command the previous
    /// keystroke executed would otherwise stay listed.
    @ObservationIgnored private let availableCommands: () -> [LauncherCommand]

    init(manager: TabManager, history: HistoryStore, ranker: LauncherRanker,
         availableCommands: @escaping () -> [LauncherCommand]) {
        self.manager = manager
        self.history = history
        self.ranker = ranker
        self.availableCommands = availableCommands
        // didSet doesn't fire during init — populate the empty-query
        // results (open tabs + recent history) for the moment of show.
        recompute()
    }

    /// Moves the keyboard selection by `delta`, CLAMPED at both ends
    /// (Spotlight-style — deliberate choice over wrap-around, recorded in
    /// the task report): ↑ at the top and ↓ at the bottom are no-ops, so
    /// holding an arrow key parks on a boundary instead of cycling.
    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    /// Resolves the selected row into the action to perform. `inNewTab`
    /// is the ⌘Enter variant and only means something for navigations —
    /// a tab switch already targets an existing tab and a command has no
    /// tab of its own, so both ignore the flag. Returns nil when there is
    /// nothing to execute (no results, or a defensively-caught
    /// out-of-range selection).
    func executeSelected(inNewTab: Bool) -> LauncherAction? {
        guard results.indices.contains(selectedIndex) else { return nil }
        switch results[selectedIndex] {
        case .switchToTab(let tab):
            return .switchToTab(tab.id)
        case .openURL(let url):
            return .navigate(url, newTab: inNewTab)
        case .searchWeb(let term):
            // Explicit search URL, never destinationURL(for:) — the term
            // may LOOK like a bare domain ("example.com"), and this row
            // promised a search, not a navigation.
            guard let url = AddressParser.searchURL(for: term) else { return nil }
            return .navigate(url, newTab: inNewTab)
        case .history(let entry):
            // History records committed http/https URLs, so this parse
            // can't realistically fail — nil-guarded rather than forced
            // all the same.
            guard let url = URL(string: entry.url) else { return nil }
            return .navigate(url, newTab: inNewTab)
        case .command(let command):
            return .run(command)
        }
    }

    // MARK: - Recompute

    private func recompute() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var historyEntries: [HistoryEntry] = []
        do {
            historyEntries = trimmed.isEmpty
                ? try history.recent(limit: Self.historyLimit)
                : try history.search(trimmed, limit: Self.historyLimit)
        } catch {
            // Same discipline as HistoryRecorder (global constraints):
            // a history failure degrades the launcher, never breaks it.
            NSLog("Nyx: launcher history lookup failed for %@: %@",
                  trimmed, String(describing: error))
        }
        results = ranker.results(query: query,
                                 openTabs: openTabCandidates(),
                                 history: historyEntries,
                                 commands: availableCommands(),
                                 limit: Self.resultLimit)
        selectedIndex = 0
    }

    /// Open tabs as switch-to-tab candidates, in the order the ranker
    /// treats as MRU: the CURRENTLY SELECTED TAB IS EXCLUDED (you are
    /// already there — "switch to the tab I'm on" would squat the top
    /// slot as a no-op; a history row for its url stays a history row,
    /// which is honest: choosing it reloads), then selected-space tabs
    /// before other spaces, most-recently-active first within each
    /// partition. "MRU-ish" per the brief: `lastActiveAt` is the
    /// manager's per-tab activation stamp — it tracks selection order,
    /// not the private webview-lifecycle MRU list, which is close enough
    /// for ranking and needs no new TabManager API.
    private func openTabCandidates() -> [LauncherTabInfo] {
        let selectedTabID = manager.selectedTabID
        let selectedSpaceID = manager.selectedSpaceID
        return manager.tabs
            .filter { $0.id != selectedTabID }
            .sorted { a, b in
                let aInSpace = a.spaceID == selectedSpaceID
                let bInSpace = b.spaceID == selectedSpaceID
                if aInSpace != bInSpace { return aInSpace }
                return a.lastActiveAt > b.lastActiveAt
            }
            .map { LauncherTabInfo(id: $0.id, title: $0.title, url: $0.urlString) }
    }
}
