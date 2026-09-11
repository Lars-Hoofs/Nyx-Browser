import AppKit

let delegate = MainActor.assumeIsolated { AppDelegate() }
// Hosted unit tests load XCTest into this process; skip the full app
// bootstrap there (UI tests launch the app in a separate process and are
// unaffected by this guard).
if NSClassFromString("XCTestCase") == nil {
    NSApplication.shared.delegate = delegate
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
