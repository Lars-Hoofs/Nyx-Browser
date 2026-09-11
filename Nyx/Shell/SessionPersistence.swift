import Foundation
import NyxCore

/// Debounced session writes (spec §4: continuous, ~2 s after change) plus
/// the synchronous flush for app termination. Writes are tens of rows —
/// doing them on the main actor behind a debounce is deliberate M2
/// simplicity; revisit only if profiling ever shows it.
@MainActor
final class SessionPersistence {
    private let store: SessionStore
    private let manager: TabManager
    private var saveTask: Task<Void, Never>?

    init(store: SessionStore, manager: TabManager) {
        self.store = store
        self.manager = manager
    }

    func restoreOrBootstrap() {
        let snapshot: SessionSnapshot
        do {
            snapshot = try store.load()
        } catch {
            NSLog("Nyx session load failed (starting fresh): %@", String(describing: error))
            snapshot = SessionSnapshot(spaces: [], tabs: [], selectedSpaceID: nil, selectedTabID: nil)
        }
        manager.restore(from: snapshot)
        manager.onStateChange = { [weak self] in self?.scheduleSave() }
        // First consumer of the targeted write path: a hibernated tab's
        // interactionState is written immediately rather than waiting for
        // the next debounced full-session save (which may be up to ~2s
        // away, or never arrive if the app is killed before then).
        manager.onTabHibernated = { [weak self] tabID, state in
            do { try self?.store.updateInteractionState(tabID: tabID, data: state) }
            catch { NSLog("Nyx: interactionState write failed: %@", String(describing: error)) }
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.performSave()
        }
    }

    func flushNow() {
        saveTask?.cancel()
        performSave()
    }

    private func performSave() {
        let snapshot = manager.snapshotForSaving()
        do {
            try store.save(snapshot)
        } catch {
            NSLog("Nyx session save failed: %@", String(describing: error))
        }
    }
}
