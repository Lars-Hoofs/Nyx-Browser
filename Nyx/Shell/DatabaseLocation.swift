import Foundation

enum DatabaseLocation {
    /// Session database path. DEBUG builds honor `-nyx-db-path <path>` so
    /// UI tests get isolated databases; read via ProcessInfo — UserDefaults
    /// mangles launch arguments (see M1 Task 11's `<`-prefix bug).
    static func url() -> URL {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flagIndex = args.firstIndex(of: "-nyx-db-path"),
           args.index(after: flagIndex) < args.count {
            let path = args[args.index(after: flagIndex)]
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        #endif
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Nyx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nyx.sqlite")
    }
}
