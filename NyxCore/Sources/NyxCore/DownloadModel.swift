// NyxCore is a plain Swift/Foundation module: it never imports AppKit,
// SwiftUI, or WebKit. Keep UI- and WebKit-facing code in the app target.

import Foundation

/// A single download's persisted state (M6 spec §5.7/§6/§7). One row per
/// `WKDownload` — created the moment a policy decision turns a navigation
/// into a download, updated on every state transition, and surviving app
/// quit/crash so it can be rebuilt on relaunch (`DownloadStore.interruptInFlight`).
public struct DownloadRecord: Codable, Equatable, Identifiable {
    /// `finished` is terminal. `interrupted` is set only by the launch
    /// rebuild (`DownloadStore.interruptInFlight`), never at runtime —
    /// see `DownloadLogic.canTransition`.
    public enum State: String, Codable {
        case running, finished, failed, cancelled, interrupted
    }

    public var id: String                  // UUID string
    public var url: String                 // source URL
    public var suggestedFilename: String
    public var destinationPath: String?    // nil until decideDestination
    public var state: State
    public var bytesReceived: Int64
    public var bytesExpected: Int64        // -1 = unknown
    public var resumeData: Data?
    public var errorMessage: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: String, url: String, suggestedFilename: String, destinationPath: String?,
                state: State, bytesReceived: Int64, bytesExpected: Int64, resumeData: Data?,
                errorMessage: String?, startedAt: Date, finishedAt: Date?) {
        self.id = id
        self.url = url
        self.suggestedFilename = suggestedFilename
        self.destinationPath = destinationPath
        self.state = state
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.resumeData = resumeData
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
