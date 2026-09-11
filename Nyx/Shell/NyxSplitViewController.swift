import AppKit

/// Sidebar (vibrancy, Arc-style) + content. The up-to-4-pane canvas
/// arrives in M3 and will live inside the content side.
final class NyxSplitViewController: NSSplitViewController {
    private let sidebarViewController: NSViewController
    private let contentViewController: NSViewController

    init(sidebar: NSViewController, content: NSViewController) {
        self.sidebarViewController = sidebar
        self.contentViewController = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin

        // NSSplitViewItem's sidebar behavior provides the
        // NSVisualEffectView (behind-window) vibrancy for free (spec §8).
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentViewController)
        contentItem.minimumThickness = 400
        addSplitViewItem(contentItem)
    }
}
