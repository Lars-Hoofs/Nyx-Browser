import SwiftUI
import AppKit
import NyxCore

/// Pure, testable row-presentation logic for `DownloadsPopover` (M6 Task 5,
/// spec §5.7/§8). No SwiftUI/WebKit types anywhere in these signatures —
/// `NyxTests/DownloadsPopoverModelTests.swift` drives every case directly.
enum DownloadsPopoverModel {

    enum RowAction: Equatable, Hashable {
        case cancel, retry, remove, reveal
    }

    /// Plan-binding action mapping (Task 5, exact): `running` -> [cancel];
    /// `failed`/`cancelled`/`interrupted` -> [retry, remove]; `finished` ->
    /// [reveal, remove].
    static func actions(for state: DownloadRecord.State) -> [RowAction] {
        switch state {
        case .running: return [.cancel]
        case .failed, .cancelled, .interrupted: return [.retry, .remove]
        case .finished: return [.reveal, .remove]
        }
    }

    /// Stale-row honesty: a `finished` row only ever OFFERS `.reveal` (see
    /// `actions` above) — this decides whether that offer is *enabled*, by
    /// checking the live filesystem through the caller-supplied
    /// `fileExists` closure rather than `FileManager` directly, so the
    /// function itself stays pure and fakeable in a test. The view
    /// (`DownloadRow.revealEnabled`) is the one place that calls this with
    /// a real `FileManager.default.fileExists(atPath:)` — checked at
    /// RENDER time, every time a row draws; nothing caches a "still
    /// exists" bit anywhere in `DownloadRecord`/`DownloadManager.Item`, so
    /// a file the user deleted or moved outside the app between popover
    /// opens is reflected honestly without any refresh hook.
    static func isRevealEnabled(record: DownloadRecord, fileExists: (String) -> Bool) -> Bool {
        guard record.state == .finished, let path = record.destinationPath else { return false }
        return fileExists(path)
    }

    /// State -> subtitle line shown under a row's host line. `running`
    /// returns a fallback the view never actually shows in practice: a
    /// `running` item always carries a live `Progress` (only an adopted,
    /// in-flight `WKDownload` is ever `running` — `rebuildFromStore()`
    /// rewrites any abandoned `running` row to `interrupted` before this
    /// view can ever see it, and a rebuilt/historical item's `progress` is
    /// simply absent, never "unknown" — M6 T3 forward note), so
    /// `DownloadRow.subtitleOrProgress` renders `ProgressView` instead
    /// whenever state is `running`. This case exists so the mapping stays
    /// total over every `DownloadRecord.State` rather than silently
    /// omitting one.
    static func subtitle(for record: DownloadRecord) -> String {
        switch record.state {
        case .running:
            return "Downloading…"
        case .finished:
            return byteFormatter.string(fromByteCount: record.bytesReceived)
        case .failed:
            return record.errorMessage ?? "Failed"
        case .cancelled:
            return "Cancelled"
        case .interrupted:
            return "Interrupted"
        }
    }

    /// Exposed (not `private`) so `DownloadsPopoverModelTests` formats its
    /// own expectation with the SAME formatter instead of hardcoding a
    /// locale-shaped literal like "4 KB".
    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Host component of the download's source URL, for a row's secondary
    /// line. "" for an unparseable URL — should not happen for a real
    /// download, but a row must never crash over it.
    static func host(for record: DownloadRecord) -> String {
        URL(string: record.url)?.host ?? ""
    }
}

/// M6 downloads popover (spec §5.7/§8): opened from the sidebar's bottom
/// "downloads" button (the spec's bottom-card slot) as a transient
/// `NSPopover` — `NyxWindowCoordinator.toggleDownloadsPopover()` owns the
/// popover host, never a separate window. Night-glass idiom matched to
/// `SidebarView`/`LauncherView`: white-opacity hairline fills/borders,
/// continuous rounded corners, SF Pro at chrome sizes (11–13pt); the ONLY
/// colors are state signals — the accent progress tint and red error text
/// (spec §8).
struct DownloadsPopover: View {
    @Bindable var manager: DownloadManager
    /// Coordinator hook: retry needs a *host* `WKWebView` to call
    /// `resumeDownload`/`startDownload` on, which this view has no access
    /// to — `NyxWindowCoordinator.retryDownload(id:)` resolves one (spec
    /// §5.7/§6: selected tab's webview, else any live one, else NSLog +
    /// no-op).
    let onRetry: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.08)
            content
            Divider().opacity(0.08)
            footer
        }
        .frame(width: Metrics.width)
        // No opaque background here (T5 review, Important#1): spec §8
        // names popovers as frosted glass. `NyxWindowCoordinator.
        // ensureDownloadsPopover()` wraps this view in an
        // `NSVisualEffectView` (the launcher-panel idiom) that supplies
        // the actual backdrop — painting an opaque color here would
        // hide that material entirely. The row fills/hairlines below
        // stay at their existing low opacities, which is what lets the
        // glass show through them.
        .accessibilityIdentifier("nyx.downloads.popover")
    }

    private enum Metrics {
        static let width: CGFloat = 340
        static let maxListHeight: CGFloat = 320
    }

    private var header: some View {
        Text("Downloads")
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if manager.items.isEmpty {
            Text("No downloads yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.items) { item in
                        DownloadRow(
                            item: item,
                            onCancel: { manager.cancel(id: item.id) },
                            onRetry: { onRetry(item.id) },
                            onRemove: { manager.remove(id: item.id) })
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: Metrics.maxListHeight)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Clear Finished") { manager.clearFinished() }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .disabled(!hasClearableItems)
                .accessibilityIdentifier("nyx.downloads.clear")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Mirrors `DownloadManager.clearFinished()`'s own scope (finished +
    /// cancelled) — disabling the footer button when there is nothing it
    /// would actually change, same restraint as `SidebarView.navButton`.
    private var hasClearableItems: Bool {
        manager.items.contains { $0.record.state == .finished || $0.record.state == .cancelled }
    }
}

/// One download row: filename + host + (running: live progress bar /
/// otherwise: state subtitle) + the row's action buttons.
private struct DownloadRow: View {
    let item: DownloadManager.Item
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    private var record: DownloadRecord { item.record }

    private var displayFilename: String {
        record.suggestedFilename.isEmpty
            ? (URL(string: record.url)?.lastPathComponent ?? "Download")
            : record.suggestedFilename
    }

    private var revealEnabled: Bool {
        DownloadsPopoverModel.isRevealEnabled(record: record) { path in
            FileManager.default.fileExists(atPath: path)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayFilename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(DownloadsPopoverModel.host(for: record))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                subtitleOrProgress
            }
            Spacer(minLength: 8)
            actionButtons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        // One a11y element per row (icon-free here, but same combine
        // discipline as SidebarView.TabRow/LauncherRowView) — the value is
        // the filename, so a UI test can find "the row for report.pdf"
        // without depending on row order.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nyx.downloads.row")
        .accessibilityValue(displayFilename)
    }

    @ViewBuilder
    private var subtitleOrProgress: some View {
        if record.state == .running, let progress = item.progress {
            // `ProgressView(_ progress: Progress)` observes the `Progress`
            // object's OWN KVO internally — it redraws on every
            // `fractionCompleted` tick regardless of whether this row's
            // @Observable-tracked `item`/`record` ever mutates in step.
            // Deliberately NOT a hand-rolled KVO/Combine wrapper: this is
            // SwiftUI's own documented, simplest-correct mechanism for
            // driving a bar off a live `Foundation.Progress` (M6 T3
            // forward note) — verified against the SDK's own
            // documentation for this initializer, not assumed.
            ProgressView(progress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
        } else {
            // Defensive fallback (see DownloadsPopoverModel.subtitle's
            // doc): a `running` row with a nil `progress` should never
            // happen, but if it ever did, this still renders SOMETHING
            // rather than an empty row.
            Text(DownloadsPopoverModel.subtitle(for: record))
                .font(.system(size: 11))
                .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                .lineLimit(1)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            ForEach(DownloadsPopoverModel.actions(for: record.state), id: \.self) { action in
                actionButton(action)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: DownloadsPopoverModel.RowAction) -> some View {
        switch action {
        case .cancel:
            iconButton("xmark.circle", action: onCancel)
        case .retry:
            iconButton("arrow.clockwise", action: onRetry)
        case .remove:
            iconButton("trash", action: onRemove)
        case .reveal:
            iconButton("folder", enabled: revealEnabled) {
                guard let path = record.destinationPath else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    private func iconButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}
