import Foundation

public struct V2DaemonHealthSnapshot: Decodable, Sendable {
    public let macDeviceID: String
    public let machineName: String
    public let relayConfigured: Bool
    public let relayConnected: Bool
    public let activeSessions: Int
    public let lastPresenceRefreshEpochMs: UInt64

    enum CodingKeys: String, CodingKey {
        case macDeviceID = "macDeviceId"
        case machineName
        case relayConfigured
        case relayConnected
        case activeSessions
        case lastPresenceRefreshEpochMs
    }
}

public struct V2RouteCandidate: Decodable, Sendable {
    public let kind: String
    public let address: String
    public let priority: UInt32
}

public struct V2SessionResolveResponse: Decodable, Sendable {
    public let ok: Bool
    public let relaySessionID: String
    public let machineName: String
    public let daemonVersion: String
    public let routeCandidates: [V2RouteCandidate]

    enum CodingKeys: String, CodingKey {
        case ok
        case relaySessionID = "relay_session_id"
        case machineName = "machine_name"
        case daemonVersion = "daemon_version"
        case routeCandidates = "route_candidates"
    }
}

public enum V2ServerFrame: Sendable {
    case sessionReady(sessionID: String, connectionMode: String, globalSequence: UInt64)
    case threadListSnapshot(globalSequence: UInt64, threadCount: Int)
    case runStarted(threadID: String, turnID: String, globalSequence: UInt64, model: String)
    case reasoning(threadID: String, turnID: String, globalSequence: UInt64, itemID: String, delta: String)
    case assistantText(threadID: String, turnID: String, globalSequence: UInt64, delta: String)
    case runCompletion(threadID: String, turnID: String, globalSequence: UInt64, result: String, errorMessage: String)
    case threadCatchUpBatch(threadID: String, latestThreadSequence: UInt64, eventCount: Int, hasMore: Bool)
    case error(code: String, message: String, retryable: Bool)
}

public struct V2ProbeResult: Sendable {
    public let daemonHealth: V2DaemonHealthSnapshot
    public let resolvedSession: V2SessionResolveResponse
    public let frames: [V2ServerFrame]
}
