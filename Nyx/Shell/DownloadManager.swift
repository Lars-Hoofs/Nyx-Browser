import Foundation
import Observation
import WebKit
import NyxCore

/// Owns every download's live + historical state for the app (M6 spec
/// §5.7/§6/§7). One `WKDownload` per adopted download; every state change
/// is validated by `DownloadLogic.canTransition` and persisted through
/// `DownloadStore` — a crash or quit loses only the in-flight bytes, never
/// the history (`rebuildFromStore()` repairs the rest on relaunch).
///
/// `WKDownload` has no public initializer — only WebKit can create one
/// (from a policy decision turning `.download`, or from
/// `WKWebView.startDownload`/`resumeDownload`). That is a real gap in this
/// type's own test suite: `adopt(_:)`, the `WKDownloadDelegate` glue
/// methods, and the network-touching branches of `retry(id:host:)` can
/// only be driven by a real download, which `DownloadManagerTests.swift`
/// documents up front rather than faking around. Internal (not `private`)
/// seams below exist purely so the guarded-transition, store-failure, and
/// naming logic can still be pinned directly.
@MainActor
@Observable
final class DownloadManager: NSObject, WKDownloadDelegate {

    /// One row's live presentation: the persisted record plus a progress
    /// object while the download is in flight. Historical items rebuilt
    /// from the store (`rebuildFromStore()`) carry `progress == nil` —
    /// there is nothing live left to observe for them.
    struct Item: Identifiable {
        let id: String
        var record: DownloadRecord
        var progress: Progress?
    }

    private let store: DownloadStore
    private let destinationDirectory: URL

    /// Newest first — matches `DownloadStore.all()`'s ordering, so a
    /// freshly-adopted download (prepended) and a rebuilt history
    /// (already ordered) present identically.
    private(set) var items: [Item] = []

    /// Coordinator hook (badge, popover refresh) — fired after every
    /// mutation to `items`, whether or not the underlying store write
    /// succeeded.
    var onItemsChanged: (() -> Void)?

    /// Live `WKDownload`s keyed by record id — needed so `cancel(id:)` and
    /// `retry(id:host:)` (via `finishRetry`) have an object to act on.
    /// Also the only strong reference keeping an in-flight download's
    /// `WKDownload` alive on our side.
    private var activeDownloads: [String: WKDownload] = [:]

    /// Reverse lookup for the delegate glue methods, which only hand back
    /// the `WKDownload` instance itself. Keyed by `ObjectIdentifier`
    /// rather than scanning `activeDownloads` so every delegate callback
    /// stays O(1); entries are removed the moment a download reaches a
    /// terminal state (`untrack`) so a later, unrelated `WKDownload`
    /// can never collide with a stale identifier.
    private var recordIDsByDownload: [ObjectIdentifier: String] = [:]

    init(store: DownloadStore, destinationDirectory: URL) {
        self.store = store
        self.destinationDirectory = destinationDirectory
        super.init()
    }

    // MARK: - Adoption

    /// Spec §5.7 (binding, silent-cancel warning): WebKit cancels a
    /// download the moment it notices no delegate has been assigned, so
    /// the assignment MUST be this method's first statement — not after
    /// building the record, not after touching `items`.
    func adopt(_ download: WKDownload) {
        download.delegate = self

        let record = Self.makeRunningRecord(url: download.originalRequest?.url)
        track(download, id: record.id)
        items.insert(Item(id: record.id, record: record, progress: download.progress), at: 0)
        persist(record)
        onItemsChanged?()
    }

    /// Test seam (internal, no `#if DEBUG`): builds the same shape of
    /// record `adopt(_:)` would, without needing a `WKDownload` (which
    /// only WebKit can construct) — so the record-creation logic itself
    /// stays pinned even though `adopt(_:)`'s delegate-assignment-order
    /// and item-prepending can't be driven from a unit test.
    static func makeRunningRecord(id: String = UUID().uuidString, url: URL?, startedAt: Date = Date()) -> DownloadRecord {
        DownloadRecord(
            id: id,
            url: url?.absoluteString ?? "",
            suggestedFilename: "",
            destinationPath: nil,
            state: .running,
            bytesReceived: 0,
            bytesExpected: -1,
            resumeData: nil,
            errorMessage: nil,
            startedAt: startedAt,
            finishedAt: nil)
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let id = recordID(for: download) else {
            // Should never happen (adopt(_:) always runs first) — refuse
            // rather than write to a location nobody is tracking.
            completionHandler(nil)
            return
        }
        let uniqueName = DownloadLogic.uniqueFilename(suggestedFilename, taken: isFilenameTaken)
        let destinationURL = destinationDirectory.appendingPathComponent(uniqueName)
        // Persist BEFORE answering (plan-binding): a store failure here
        // must never delay or block the download itself.
        updateRecord(id: id) { record in
            record.suggestedFilename = suggestedFilename
            record.destinationPath = destinationURL.path
        }
        onItemsChanged?()
        completionHandler(destinationURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = recordID(for: download) else { return }
        transition(id: id, to: .finished) { record in
            record.finishedAt = Date()
        }
        untrack(id: id, download: download)
        onItemsChanged?()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = recordID(for: download) else { return }
        // Spec §6: NSLog, never a dialog, never a crash.
        NSLog("DownloadManager: download %@ failed: %@", id, String(describing: error))
        transition(id: id, to: .failed) { record in
            record.resumeData = resumeData
            record.errorMessage = error.localizedDescription
        }
        untrack(id: id, download: download)
        onItemsChanged?()
    }

    // MARK: - User actions

    /// No-op for an id with no live download (already finished/failed/
    /// removed, or unknown) — cancelling is only meaningful in flight.
    func cancel(id: String) {
        guard let download = activeDownloads[id] else { return }
        download.cancel { [weak self] resumeData in
            guard let self else { return }
            self.transition(id: id, to: .cancelled) { record in
                record.resumeData = resumeData
            }
            self.untrack(id: id, download: download)
            self.onItemsChanged?()
        }
    }

    /// Spec §6: resumeData present → resume; nil → fresh-restart fallback.
    /// nil `RetryAction` (record is `finished` or `running`) → no-op —
    /// there is nothing to retry. Reuses the SAME record id throughout:
    /// the retried download is a continuation of this row, not a new one.
    func retry(id: String, host: WKWebView) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let record = items[index].record
        guard let action = DownloadLogic.retryAction(for: record) else { return }

        switch action {
        case .resume(let data):
            host.resumeDownload(fromResumeData: data) { [weak self] download in
                self?.finishRetry(id: id, download: download)
            }
        case .freshStart:
            guard let url = URL(string: record.url) else {
                NSLog("DownloadManager: cannot retry download %@ — stored URL %@ is invalid.", id, record.url)
                return
            }
            host.startDownload(using: URLRequest(url: url)) { [weak self] download in
                self?.finishRetry(id: id, download: download)
            }
        }
    }

    /// Same silent-cancel warning as `adopt(_:)` — the delegate assignment
    /// is this method's first statement.
    private func finishRetry(id: String, download: WKDownload) {
        download.delegate = self
        track(download, id: id)
        transition(id: id, to: .running) { record in
            record.resumeData = nil
            record.errorMessage = nil
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].progress = download.progress
        }
        onItemsChanged?()
    }

    /// Never cancels a running download — remove is a history-list
    /// action, not a stop button. Deletes the store row and drops the
    /// item; a store failure still drops the in-memory item (spec §6:
    /// storage trouble never blocks the user-visible action).
    func remove(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].record.state != .running else {
            NSLog("DownloadManager: refusing to remove running download %@; cancel it first.", id)
            return
        }
        items.remove(at: index)
        activeDownloads.removeValue(forKey: id)
        do {
            try store.delete(id: id)
        } catch {
            NSLog("DownloadManager: failed to delete download %@ from store (%@); removed from memory anyway.",
                  id, String(describing: error))
        }
        onItemsChanged?()
    }

    /// Mirrors `DownloadStore.clearFinished()`'s semantics: `finished` and
    /// `cancelled` rows only — `running`, `failed`, `interrupted` stay.
    func clearFinished() {
        items.removeAll { $0.record.state == .finished || $0.record.state == .cancelled }
        do {
            try store.clearFinished()
        } catch {
            NSLog("DownloadManager: clearFinished failed to persist (%@); in-memory items cleared anyway.",
                  String(describing: error))
        }
        onItemsChanged?()
    }

    /// Called once by the coordinator at startup (T4 wires this — not
    /// this file's job). Repairs any `running` row abandoned by the last
    /// quit/crash (spec §5.7: in-flight downloads die with the app) and
    /// loads the rest as progress-less items — there is nothing live left
    /// to mirror for a download from a previous launch.
    func rebuildFromStore() {
        do {
            _ = try store.interruptInFlight()
        } catch {
            NSLog("DownloadManager: interruptInFlight failed (%@); history may still show stale running rows.",
                  String(describing: error))
        }
        do {
            items = try store.all().map { Item(id: $0.id, record: $0, progress: nil) }
        } catch {
            NSLog("DownloadManager: failed to load download history (%@).", String(describing: error))
            items = []
        }
        onItemsChanged?()
    }

    // MARK: - Test seams

    /// Builds an item directly (bypassing `adopt(_:)`, which needs a real
    /// `WKDownload`) so `cancel`/`remove`/`clearFinished`/`retry`'s no-op
    /// paths, and `transition`'s guard, can be exercised against items
    /// with a known, chosen state.
    func seedForTesting(_ record: DownloadRecord, progress: Progress? = nil) {
        items.insert(Item(id: record.id, record: record, progress: progress), at: 0)
    }

    /// The exact `taken` predicate `decideDestination` wires into
    /// `DownloadLogic.uniqueFilename` — a full-path `fileExists` check
    /// against `destinationDirectory`, not just a bare filename compare.
    func isFilenameTaken(_ candidate: String) -> Bool {
        FileManager.default.fileExists(atPath: destinationDirectory.appendingPathComponent(candidate).path)
    }

    /// Every guarded state change goes through here. An invalid
    /// transition (per `DownloadLogic.canTransition`) is logged and
    /// otherwise ignored — `mutate` is never even called, so a caller
    /// can't sneak a field change through under cover of a rejected
    /// transition.
    func transition(id: String, to newState: DownloadRecord.State, mutate: (inout DownloadRecord) -> Void = { _ in }) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var record = items[index].record
        guard DownloadLogic.canTransition(from: record.state, to: newState) else {
            NSLog("DownloadManager: ignoring invalid transition for download %@ (%@ -> %@).",
                  id, record.state.rawValue, newState.rawValue)
            return
        }
        record.state = newState
        mutate(&record)
        items[index].record = record
        persist(record)
    }

    /// Field-level updates that don't change `state` (only
    /// `decideDestination` uses this — naming a destination isn't itself
    /// a state transition).
    func updateRecord(id: String, mutate: (inout DownloadRecord) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var record = items[index].record
        mutate(&record)
        items[index].record = record
        persist(record)
    }

    // MARK: - Private helpers

    private func track(_ download: WKDownload, id: String) {
        activeDownloads[id] = download
        recordIDsByDownload[ObjectIdentifier(download)] = id
    }

    private func untrack(id: String, download: WKDownload) {
        activeDownloads.removeValue(forKey: id)
        recordIDsByDownload.removeValue(forKey: ObjectIdentifier(download))
    }

    private func recordID(for download: WKDownload) -> String? {
        recordIDsByDownload[ObjectIdentifier(download)]
    }

    /// Spec §6: storage trouble never breaks the download — log and keep
    /// whatever's already in `items` as the source of truth.
    private func persist(_ record: DownloadRecord) {
        do {
            try store.upsert(record)
        } catch {
            NSLog("DownloadManager: failed to persist download %@ (%@); in-memory state kept.",
                  record.id, String(describing: error))
        }
    }
}
