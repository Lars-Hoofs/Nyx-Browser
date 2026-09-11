import Foundation

enum DatabaseLocation {
    /// Session database path. DEBUG builds honor `-nyx-db-name <name>` so
    /// UI tests get isolated databases that resolve INSIDE the app's own
    /// sandbox container — the app cannot open files in the test runner's
    /// temp directory (SQLite error 14). `-nyx-db-path <path>` is kept for
    /// manual/debug use outside the sandbox. Read via ProcessInfo —
    /// UserDefaults mangles launch arguments (see M1 Task 11's `<`-prefix
    /// bug).
    static func url() -> URL {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flagIndex = args.firstIndex(of: "-nyx-db-name"),
           args.index(after: flagIndex) < args.count {
            let name = args[args.index(after: flagIndex)]
            let dir = applicationSupportDirectory()
                .appendingPathComponent("UITests", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("\(name).sqlite")
        }
        if let flagIndex = args.firstIndex(of: "-nyx-db-path"),
           args.index(after: flagIndex) < args.count {
            let path = args[args.index(after: flagIndex)]
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        #endif
        let dir = applicationSupportDirectory()
        return dir.appendingPathComponent("nyx.sqlite")
    }

    private static func applicationSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Nyx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
