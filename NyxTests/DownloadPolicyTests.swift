import XCTest
import WebKit
@testable import Nyx
import NyxCore

/// M6 Task 4: NavigationRelay's download policy (spec §5.7) — the pure
/// canShowMIMEType/Content-Disposition matrix behind the response
/// decision, plus the adoption funnel's wiring through TabManager.
///
/// What only the queued runs can prove (documented honestly, T3
/// precedent — never faked around):
/// - The `didBecome` handlers' actual handoff, and therefore the
///   end-to-end funnel firing: they take a real `WKDownload`, and
///   `WKDownload()` COMPILES but traps at runtime (verified: SIGTRAP on
///   this exact SDK from a bare construction) — only WebKit can make
///   one. So the tests below pin that the funnel closures are WIRED
///   (non-nil, from every tab-creation site); invoking them with a live
///   download is T6's queued UI test's job.
/// - `decidePolicyFor` as WebKit calls it on real navigations. The
///   `.allow` default is a one-expression passthrough here; the existing
///   12-test UI suite (queued) is the regression gate that ordinary
///   browsing still navigates.
/// - `shouldDownload(_ response:)`'s three-line WebKit-reading wrapper
///   (`canShowMIMEType` + header fetch) — WKNavigationResponse is not
///   meaningfully constructible either; the logic it feeds is fully
///   pinned below via the (canShowMIMEType:contentDisposition:) overload.
@MainActor
final class DownloadPolicyTests: XCTestCase {

    // MARK: - Header matrix (pure static, no WebKit fakes)

    func testShowableWithNoHeaderAllows() {
        XCTAssertFalse(NavigationRelay.shouldDownload(
            canShowMIMEType: true, contentDisposition: nil))
    }

    func testShowableAttachmentDownloads() {
        XCTAssertTrue(NavigationRelay.shouldDownload(
            canShowMIMEType: true, contentDisposition: "attachment"))
    }

    func testShowableAttachmentWithFilenameDownloads() {
        XCTAssertTrue(NavigationRelay.shouldDownload(
            canShowMIMEType: true, contentDisposition: "attachment; filename=x"))
    }

    func testShowableUppercaseAttachmentWithLeadingWhitespaceDownloads() {
        XCTAssertTrue(NavigationRelay.shouldDownload(
            canShowMIMEType: true, contentDisposition: "  ATTACHMENT"))
    }

    func testShowableTabIndentedMixedCaseAttachmentDownloads() {
        XCTAssertTrue(NavigationRelay.shouldDownload(
            canShowMIMEType: true, contentDisposition: "\tAttachment; filename=\"r.pdf\""))
    }

    func testShowableInlineAllows() {
        XCTAssertFalse(NavigationRelay.shouldDownload(
            canShowMIMEType: true, contentDisposition: "inline"))
    }

    func testShowableInlineWithFilenameAllows() {
        XCTAssertFalse(NavigationRelay.shouldDownload(
            canShowMIMEType: true, contentDisposition: "inline; filename=x"))
    }

    /// !canShowMIMEType downloads regardless of the header — including
    /// nil (the non-HTTP-response encoding: no header exists at all).
    func testUnshowableAlwaysDownloads() {
        for header in [nil, "", "inline", "inline; filename=x",
                       "attachment", "form-data", "  garbage  "] {
            XCTAssertTrue(
                NavigationRelay.shouldDownload(
                    canShowMIMEType: false, contentDisposition: header),
                "expected download for un-showable type with header \(header ?? "nil")")
        }
    }

    /// Pins the prefix rule's honest edge: an empty or unrelated value on
    /// a SHOWABLE type allows — only the "attachment" prefix downloads.
    func testShowableUnrelatedValuesAllow() {
        for header in ["", "form-data", "attach", "x-attachment"] {
            XCTAssertFalse(
                NavigationRelay.shouldDownload(
                    canShowMIMEType: true, contentDisposition: header),
                "expected allow for showable type with header \(header)")
        }
    }

    // MARK: - Funnel wiring (TabManager seam — see header for why the
    // closures are asserted wired, not invoked)

    func testNewTabIsWiredIntoDownloadFunnel() {
        let manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 2))
        let tab = manager.newTab()
        XCTAssertNotNil(tab.onDownloadStarted,
                        "registerCallbacks must thread onDownloadStarted on newTab")
    }

    func testRestoredTabIsWiredIntoDownloadFunnel() {
        let manager = TabManager(policy: TabLifecyclePolicy())
        let space = SpaceRecord(id: "s1", name: "Space", orderIndex: 0)
        let record = TabRecord(id: "t1", spaceID: "s1", urlString: "", title: "",
                               orderIndex: 0, interactionState: nil, lastActiveAt: Date())
        manager.restore(from: SessionSnapshot(
            spaces: [space], tabs: [record],
            selectedSpaceID: "s1", selectedTabID: "t1"))
        XCTAssertNotNil(manager.tabs.first?.onDownloadStarted,
                        "registerCallbacks must thread onDownloadStarted on restore")
    }

    /// The tab-level closure reads the manager's CURRENT callback at fire
    /// time ([weak self] passthrough), so wiring the manager-level
    /// callback AFTER the tab exists must still connect — the coordinator
    /// installs its callback in init, but the shape must not depend on
    /// ordering. Pinned structurally: the tab closure survives (stays
    /// non-nil) across a late manager-callback install.
    func testLateManagerCallbackInstallKeepsTabWiring() {
        let manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 2))
        let tab = manager.newTab()
        manager.onDownloadStarted = { _ in }
        XCTAssertNotNil(tab.onDownloadStarted)
        XCTAssertNotNil(manager.onDownloadStarted)
    }
}
