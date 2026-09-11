import Foundation
import WebKit
import NyxCore

/// One AdBlock-syntax filter list to bootstrap into `WKContentRuleListStore`.
/// `load` is deferred (not eagerly read) so tests can point it at a tiny
/// in-memory fixture instead of the real, much larger bundled snapshots.
struct FilterListSource {
    let name: String
    let load: () throws -> String
}

/// Compiles Nyx's WebKit content-blocker rule lists and hands them out for
/// per-tab application, per spec §5.6.
///
/// Cache semantics: `FilterListConverter`'s identifiers are content-addressed
/// (a hash of the source text) — the same source text always produces the
/// same identifier, so a `WKContentRuleListStore` hit for that identifier
/// means "already compiled, still correct", with no extra version
/// bookkeeping needed. Conversion (AdBlock syntax → WebKit JSON) is fast —
/// ~1.4s total for the real bundled EasyList + EasyPrivacy snapshots, see
/// `RuleListManagerTests.testMeasuredCompileTimeForRealBundledLists` — so
/// it runs on every `bootstrap()` purely to derive identifiers to look up.
/// The expensive, duration-unknown step is the WebKit *compile*, and that
/// only happens for identifiers `bootstrap()` doesn't already find in the
/// store; `compileInvocationCount` is a test seam that counts real compiles
/// so a cache-hit run can be asserted deterministically instead of by timing
/// alone.
///
/// Failure never blocks browsing (spec §6): any error along the way —
/// loading a bundled resource, conversion, or compile — is logged via
/// `NSLog` and swallowed; `isReady` simply stays `false` (webviews run with
/// no rule lists applied) and `bootstrap()` retries itself exactly once,
/// 30s later, before giving up silently.
@MainActor
final class RuleListManager {
    /// `nonisolated` because it's referenced from an initializer default
    /// value, which Swift evaluates outside this type's actor isolation —
    /// the closures it holds (plain NyxCore functions) carry no
    /// actor-isolated state, so this is safe.
    nonisolated static let defaultSources: [FilterListSource] = [
        FilterListSource(name: "easylist", load: BundledFilterLists.easyList),
        FilterListSource(name: "easyprivacy", load: BundledFilterLists.easyPrivacy),
    ]

    private let store: WKContentRuleListStore
    private let sources: [FilterListSource]
    private var bootstrapTask: Task<Void, Never>?

    private(set) var compiledLists: [WKContentRuleList] = []
    private(set) var isReady = false
    var onReady: (() -> Void)?

    /// Test seam: total number of rule lists actually sent to
    /// `WKContentRuleListStore.compileContentRuleList` across this
    /// manager's lifetime (as opposed to satisfied via `lookUpContentRuleList`
    /// cache hits). Lets a cache-hit bootstrap be asserted deterministically.
    private(set) var compileInvocationCount = 0

    /// `store` defaults to `nil` (resolved to `.default()` in the body)
    /// rather than `= .default()` directly: `WKContentRuleListStore` is
    /// itself `@MainActor`-isolated by WebKit, and Swift evaluates
    /// initializer default *values* outside the declaring type's
    /// isolation — a default of `.default()` there triggers an actor-
    /// isolation warning even though this whole type is `@MainActor`.
    init(store: WKContentRuleListStore? = nil, sources: [FilterListSource] = RuleListManager.defaultSources) {
        self.store = store ?? .default()
        self.sources = sources
    }

    deinit {
        bootstrapTask?.cancel()
    }

    /// Launch path: convert the configured filter lists (fast), look each
    /// resulting identifier up in the store, compile only the misses, apply
    /// the compiled result, then prune any stale identifiers left over from
    /// a previous source version. Never throws; failures retry once after
    /// 30s and otherwise fail silently with browsing unblocked.
    func bootstrap() {
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.runBootstrap(isRetry: false)
        }
    }

    /// Adds every compiled list to `controller`. Idempotent in the sense
    /// that calling it again after `remove(from:)` restores the same set;
    /// calling it twice without an intervening `remove` is a WebKit-level
    /// no-op/duplicate concern, not this method's.
    func apply(to controller: WKUserContentController) {
        for list in compiledLists {
            controller.add(list)
        }
    }

    /// Removes all rule lists from `controller`, compiled-by-us or not
    /// (matches `WKUserContentController.removeAllContentRuleLists`).
    func remove(from controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
    }

    private func runBootstrap(isRetry: Bool) async {
        guard !Task.isCancelled else { return }
        do {
            let converted = try await Self.convert(sources)
            let lists = try await compile(converted)
            compiledLists = lists
            isReady = true
            onReady?()
            await pruneStaleIdentifiers(keeping: Set(converted.map(\.identifier)))
        } catch {
            NSLog(
                "RuleListManager: bootstrap failed (%@); browsing continues unblocked.",
                String(describing: error)
            )
            guard !isRetry, !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await runBootstrap(isRetry: true)
        }
    }

    /// Loads + converts `sources` off the main actor. Conversion itself is
    /// cheap (see type doc) so this always runs, even on a full cache hit.
    private static func convert(_ sources: [FilterListSource]) async throws -> [ConvertedRuleList] {
        try await Task.detached {
            try sources.flatMap { source in
                try FilterListConverter.convert(name: source.name, filterText: try source.load())
            }
        }.value
    }

    /// Looks each converted list up in the store first; compiles (which
    /// also stores it under its identifier) only the ones missing.
    ///
    /// Internal rather than `private`: NyxTests exercises it directly with
    /// a hand-built `ConvertedRuleList` carrying deliberately malformed
    /// JSON, to verify WebKit's own rejection surfaces as a thrown Swift
    /// error rather than a crash or a silently-accepted nil list — the
    /// "corrupt JSON" failure path is otherwise unreachable through
    /// `bootstrap()` alone, since `FilterListConverter` only ever emits
    /// well-formed JSON for real filter-list text.
    func compile(_ converted: [ConvertedRuleList]) async throws -> [WKContentRuleList] {
        var result: [WKContentRuleList] = []
        result.reserveCapacity(converted.count)
        for entry in converted {
            if let cached = try? await store.contentRuleList(forIdentifier: entry.identifier) {
                result.append(cached)
            } else {
                compileInvocationCount += 1
                guard let compiled = try await store.compileContentRuleList(
                    forIdentifier: entry.identifier,
                    encodedContentRuleList: entry.json
                ) else {
                    throw RuleListManagerError.compileFailed(identifier: entry.identifier)
                }
                result.append(compiled)
            }
        }
        return result
    }

    /// Removes any identifier the store holds that isn't part of the
    /// current source set — left behind by a previous app version's
    /// filter-list content (a different content hash → a different
    /// identifier, orphaning the old one).
    private func pruneStaleIdentifiers(keeping current: Set<String>) async {
        let available = Set(await store.availableIdentifiers() ?? [])
        for identifier in available.subtracting(current) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }
}

enum RuleListManagerError: Error, Equatable {
    /// `compileContentRuleList` returned a nil list with no error — should
    /// not happen in practice; guards against silently treating that as
    /// success.
    case compileFailed(identifier: String)
}
