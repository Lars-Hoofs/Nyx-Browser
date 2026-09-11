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
        let snapshot = (try? store.load())
            ?? SessionSnapshot(spaces: [], tabs: [], selectedSpaceID: nil, selectedTabID: nil)
        manager.restore(from: snapshot)
        manager.onStateChange = { [weak self] in self?.scheduleSave() }
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
