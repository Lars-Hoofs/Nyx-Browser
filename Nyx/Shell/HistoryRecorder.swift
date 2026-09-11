import Foundation
import NyxCore

/// Bridges BrowserTab's navigation/title events into the persistent
/// HistoryStore (M4 spec §7). Records http/https visits only; never
/// blocks navigation and never throws out of its own closures — a store
/// failure is logged and dropped (global constraints: try? + NSLog).
@MainActor
final class HistoryRecorder {
    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
    }

    /// Wires a tab's navigation-committed and title-changed hooks. Called
    /// once per runtime tab (TabManager.onTabCreated fires exactly once
    /// per creation site: newTab, popup adoption, restore's rebuild loop).
    func wire(_ tab: BrowserTab) {
        tab.onNavigationCommitted = { [weak self] url in
            guard let self, Self.isRecordable(url) else { return }
            // Title is intentionally NOT read from `tab.title` here: didCommit
            // fires while the webview still carries the PREVIOUS page's title
            // (the new document hasn't parsed far enough to report one yet),
            // so passing it through would mislabel a brand-new URL with the
            // old page's title. recordVisit's own semantics handle this
            // correctly: an empty title inserts cleanly for a new row, or is
            // ignored in favor of the existing title on a repeat visit — the
            // title-changed hook below enriches once the real title arrives.
            do {
                try self.store.recordVisit(url: url.absoluteString, title: "", at: Date())
            } catch {
                NSLog("Nyx: history recordVisit failed for %@: %@",
                      url.absoluteString, String(describing: error))
            }
        }
        tab.onTitleChangedForHistory = { [weak self] url, title in
            // The URL comes from BrowserTab's KVO-synchronous capture, not
            // tab.urlString (which advances via its own, independently
            // scheduled Task) — using it directly is what keeps a title
            // event from ever landing on the wrong row across a fast
            // same-tab renavigation.
            guard let self, Self.isRecordable(url) else { return }
            do {
                try self.store.updateTitle(url: url.absoluteString, title: title)
            } catch {
                NSLog("Nyx: history updateTitle failed for %@: %@",
                      url.absoluteString, String(describing: error))
            }
        }
    }

    /// Pure, testable: only http/https URLs enter history (M4 spec) —
    /// about:, data:, file:, and blob: pages never do.
    nonisolated static func isRecordable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return true
        default: return false
        }
    }
}
