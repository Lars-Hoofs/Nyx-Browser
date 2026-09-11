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
    public var splitGroupID: String?

    public init(id: String, spaceID: String, urlString: String, title: String,
                orderIndex: Int, interactionState: Data?, lastActiveAt: Date,
                splitGroupID: String? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.urlString = urlString
        self.title = title
        self.orderIndex = orderIndex
        self.interactionState = interactionState
        self.lastActiveAt = lastActiveAt
        self.splitGroupID = splitGroupID
    }
}

/// A split group (M3 spec §5): a flat column of tabs within a space with
/// per-pane weights. `weightsJSON` stores the weights as a JSON-encoded
/// `[Double]` since GRDB records are flat rows.
public struct SplitGroupRecord: Codable, Equatable, Identifiable,
                                FetchableRecord, PersistableRecord {
    public static let databaseTableName = "split_group"
    public var id: String
    public var spaceID: String
    public var orderIndex: Int
    public var weightsJSON: String

    public init(id: String, spaceID: String, orderIndex: Int, weightsJSON: String) {
        self.id = id
        self.spaceID = spaceID
        self.orderIndex = orderIndex
        self.weightsJSON = weightsJSON
    }

    public var weights: [Double] {
        guard let data = weightsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Double].self, from: data)
        else { return [] }
        return decoded
    }

    public static func encodeWeights(_ weights: [Double]) -> String {
        guard let data = try? JSONEncoder().encode(weights),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

public struct SessionSnapshot: Equatable {
    public var spaces: [SpaceRecord]
    public var tabs: [TabRecord]
    public var splitGroups: [SplitGroupRecord]
    public var selectedSpaceID: String?
    public var selectedTabID: String?

    public init(spaces: [SpaceRecord], tabs: [TabRecord],
                splitGroups: [SplitGroupRecord] = [],
                selectedSpaceID: String?, selectedTabID: String?) {
        self.spaces = spaces
        self.tabs = tabs
        self.splitGroups = splitGroups
        self.selectedSpaceID = selectedSpaceID
        self.selectedTabID = selectedTabID
    }
}
