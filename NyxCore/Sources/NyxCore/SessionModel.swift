// NyxCore is a plain Swift/Foundation module: it never imports AppKit,
// SwiftUI, or WebKit. Keep UI- and WebKit-facing code in the app target.

import Foundation
import GRDB

/// Persistent session records (spec §4). IDs are UUID strings; a
/// SessionItem/SplitGroup layer arrives in M3 — the flat tab list with
/// orderIndex is forward-compatible with it.
public struct SpaceRecord: Codable, Equatable, Identifiable,
                           FetchableRecord, PersistableRecord {
    public static let databaseTableName = "space"
    public var id: String
    public var name: String
    public var orderIndex: Int

    public init(id: String, name: String, orderIndex: Int) {
        self.id = id
        self.name = name
        self.orderIndex = orderIndex
    }
}

public struct TabRecord: Codable, Equatable, Identifiable,
                         FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tab"
    public var id: String
    public var spaceID: String
    public var urlString: String
    public var title: String
    public var orderIndex: Int
    public var interactionState: Data?
    public var lastActiveAt: Date

    public init(id: String, spaceID: String, urlString: String, title: String,
                orderIndex: Int, interactionState: Data?, lastActiveAt: Date) {
        self.id = id
        self.spaceID = spaceID
        self.urlString = urlString
        self.title = title
        self.orderIndex = orderIndex
        self.interactionState = interactionState
        self.lastActiveAt = lastActiveAt
    }
}

public struct SessionSnapshot: Equatable {
    public var spaces: [SpaceRecord]
    public var tabs: [TabRecord]
    public var selectedSpaceID: String?
    public var selectedTabID: String?

    public init(spaces: [SpaceRecord], tabs: [TabRecord],
                selectedSpaceID: String?, selectedTabID: String?) {
        self.spaces = spaces
        self.tabs = tabs
        self.selectedSpaceID = selectedSpaceID
        self.selectedTabID = selectedTabID
    }
}
