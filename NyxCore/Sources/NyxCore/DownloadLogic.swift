import Foundation

/// Pure decision logic for downloads (M6 spec §7 headless state machine).
/// No I/O, no WebKit — the manager (Shell) is the only caller of record
/// mutation; this type only answers questions.
public enum DownloadLogic {

    /// Valid state transitions; the manager refuses anything else (spec §7).
    /// `running` is the only state with outgoing transitions to a terminal
    /// outcome (`finished`/`failed`/`cancelled`); `failed`/`cancelled`/
    /// `interrupted` may only go back to `running` (a retry). `finished` is
    /// terminal — no outgoing transitions. `interrupted` is never a valid
    /// destination at runtime: it is written only by the launch rebuild
    /// (`DownloadStore.interruptInFlight`), which bypasses this check.
    public static func canTransition(from: DownloadRecord.State, to: DownloadRecord.State) -> Bool {
        switch (from, to) {
        case (.running, .finished), (.running, .failed), (.running, .cancelled):
            return true
        case (.failed, .running), (.cancelled, .running), (.interrupted, .running):
            return true
        default:
            return false
        }
    }

    /// "report.pdf" taken → "report (2).pdf"; preserves the extension,
    /// increments until free. `taken` is asked about each candidate in turn
    /// (the suggested name first) — the first one it reports free is
    /// returned, without probing further. Candidates are passed to `taken`
    /// verbatim: this function does no case-folding of its own, so the
    /// caller's closure decides comparison semantics (e.g. matching
    /// case-insensitively, as `DownloadManager` does).
    ///
    /// Contract: for normal operation `taken` is expected to eventually
    /// return `false` for one of the probed candidates (i.e. collisions are
    /// finite). If it does not — a pathological always-true closure, or an
    /// implausibly long real collision run — this function still
    /// terminates: after `maxProbeAttempts` probes it stops consulting
    /// `taken` and returns the next counter-suffixed candidate
    /// unconditionally. That termination guarantee holds regardless of what
    /// `taken` does; only the *shape* of the fallback name is affected by
    /// the pathological case, never whether the call returns.
    public static func uniqueFilename(_ suggested: String, taken: (String) -> Bool) -> String {
        guard taken(suggested) else { return suggested }

        let (base, ext) = lastDotSplit(suggested)
        var counter = 2
        while counter <= maxProbeAttempts {
            let candidate = ext.map { "\(base) (\(counter)).\($0)" } ?? "\(base) (\(counter))"
            if !taken(candidate) { return candidate }
            counter += 1
        }
        // Defensive bound reached: `taken` reported every candidate through
        // "(\(maxProbeAttempts))" as taken. Rather than loop forever, fall
        // back to the next counter value UNCONDITIONALLY — without calling
        // `taken` again — so the function is guaranteed to terminate. The
        // caller's fileExists-race handling downstream is unchanged either
        // way: it already tolerates being handed a name that turns out to
        // collide.
        return ext.map { "\(base) (\(counter)).\($0)" } ?? "\(base) (\(counter))"
    }

    /// Hard bound on probe attempts in `uniqueFilename`, guarding against a
    /// pathological `taken` closure that always returns `true` (which would
    /// otherwise hang the caller forever). 1000 is comfortably above any
    /// realistic collision count for real filesystem naming.
    private static let maxProbeAttempts = 1000

    /// Splits on the LAST '.' only (so "archive.tar.gz" → base "archive.tar",
    /// ext "gz" — the counter lands right before the final extension, not
    /// the first one). A leading dot with nothing before it (".zshrc") is
    /// not an extension separator: dotfiles have no extension. A name with
    /// no dot, or a trailing empty extension, also has no extension.
    private static func lastDotSplit(_ name: String) -> (base: String, ext: String?) {
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
            return (name, nil)
        }
        let base = String(name[name.startIndex..<dotIndex])
        let ext = String(name[name.index(after: dotIndex)...])
        return (base, ext.isEmpty ? nil : ext)
    }

    /// Spec §6: resumeData present → .resume(data); nil → .freshStart.
    public enum RetryAction: Equatable {
        case resume(Data)
        case freshStart
    }

    /// nil when not retryable (`finished` is terminal, `running` is already
    /// in flight). Otherwise (`failed`/`cancelled`/`interrupted`): resumeData
    /// present → resume with it, nil → fresh-restart fallback.
    public static func retryAction(for record: DownloadRecord) -> RetryAction? {
        switch record.state {
        case .finished, .running:
            return nil
        case .failed, .cancelled, .interrupted:
            if let data = record.resumeData {
                return .resume(data)
            }
            return .freshStart
        }
    }
}
