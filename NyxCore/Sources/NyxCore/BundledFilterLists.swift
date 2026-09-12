import Foundation

/// Bundled filter list snapshots, downloaded from canonical sources and frozen
/// into the app bundle for M5 first-run processing. Both lists use `.process()`
/// in Package.swift to load from NyxCore/Resources/ via Bundle.module.
public enum BundledFilterLists {
    /// EasyList — general ad-blocking rules
    /// Downloaded: 2026-09-11 21:27:12 UTC
    /// License: GPLv3 and CC BY-SA 3.0
    /// Source: https://easylist.to/easylist/easylist.txt
    public static func easyList() throws -> String {
        try loadResource(named: "easylist")
    }

    /// EasyPrivacy — privacy/tracking rules
    /// Downloaded: 2026-09-11 21:27:12 UTC
    /// License: GPLv3 and CC BY-SA 3.0
    /// Source: https://easylist.to/easylist/easyprivacy.txt
    public static func easyPrivacy() throws -> String {
        try loadResource(named: "easyprivacy")
    }

    private static func loadResource(named name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            throw BundledFilterListsError.resourceNotFound(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

public enum BundledFilterListsError: Error, Equatable {
    case resourceNotFound(String)
}
