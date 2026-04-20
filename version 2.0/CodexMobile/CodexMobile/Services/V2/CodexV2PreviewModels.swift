// FILE: CodexV2PreviewModels.swift
// Purpose: Lightweight models for the Version 2.0 preview transport inside the iOS app snapshot.
// Layer: Service support
// Exports: V2 preview transport models and timeline state

import Foundation

struct CodexV2DaemonHealthSnapshot: Decodable, Sendable {
    let macDeviceID: String
    let machineName: String
    let runtimeMode: String?
    let workspaceRoot: String?
    let configuredModel: String?
    let relayConfigured: Bool
    let relayConnected: Bool
    let activeSessions: Int
    let lastPresenceRefreshEpochMs: UInt64

    enum CodingKeys: String, CodingKey {
        case macDeviceID = "macDeviceId"
        case machineName
        case runtimeMode
        case workspaceRoot
        case configuredModel
        case relayConfigured
        case relayConnected
        case activeSessions
        case lastPresenceRefreshEpochMs
    }
}

struct CodexV2RouteCandidate: Decodable, Sendable {
    let kind: String
    let address: String
    let priority: UInt32
}

struct CodexV2SessionResolveResponse: Decodable, Sendable {
    let ok: Bool
    let relaySessionID: String
    let machineName: String
    let daemonVersion: String
    let routeCandidates: [CodexV2RouteCandidate]

    enum CodingKeys: String, CodingKey {
        case ok
        case relaySessionID = "relay_session_id"
        case machineName = "machine_name"
        case daemonVersion = "daemon_version"
        case routeCandidates = "route_candidates"
    }
}

struct CodexV2ThreadSummary: Sendable, Hashable {
    let threadID: String
    let title: String
    let preview: String
    let updatedAtMs: UInt64
    let isRunning: Bool
}

enum CodexV2ThreadEventPayload: Sendable, Equatable {
    case userMessage(turnID: String, text: String)
    case assistantDelta(turnID: String, delta: String)
    case reasoningDelta(turnID: String, itemID: String, delta: String)
    case toolDelta(turnID: String, callID: String, delta: String)
    case statusChanged(turnID: String, status: String)
}

struct CodexV2ThreadEvent: Sendable, Equatable {
    let sequence: UInt64
    let payload: CodexV2ThreadEventPayload
}

enum CodexV2ConversationItemRole: Sendable, Equatable {
    case user
    case assistant
    case reasoning
    case error
}

struct CodexV2ConversationItem: Identifiable, Sendable, Equatable {
    let id: String
    var threadID: String
    var turnID: String?
    let role: CodexV2ConversationItemRole
    var text: String
    var isStreaming: Bool
    var reasoningItemID: String?
}

struct CodexV2PendingPrompt: Identifiable, Sendable, Equatable {
    let id: String
    let conversationItemID: String
    var threadID: String
}

struct CodexV2ThreadRecoverySnapshot: Sendable, Equatable {
    let latestThreadSequence: UInt64
    let eventCount: Int
    let hasMore: Bool
}

struct CodexV2ConversationState: Sendable, Equatable {
    var messagesByThreadID: [String: [CodexV2ConversationItem]] = [:]
    var pendingPrompts: [CodexV2PendingPrompt] = []
    var recoveryByThreadID: [String: CodexV2ThreadRecoverySnapshot] = [:]
}

enum CodexV2ReconnectState: Sendable, Equatable {
    case idle
    case reconnecting(attempt: Int)

    var attemptCount: Int {
        switch self {
        case .idle:
            return 0
        case .reconnecting(let attempt):
            return attempt
        }
    }
}

enum CodexV2ServerFrame: Sendable {
    case sessionReady(sessionID: String, connectionMode: String, globalSequence: UInt64)
    case threadListSnapshot(globalSequence: UInt64, threads: [CodexV2ThreadSummary])
    case runStarted(threadID: String, turnID: String, globalSequence: UInt64, model: String)
    case reasoning(threadID: String, turnID: String, globalSequence: UInt64, itemID: String, delta: String)
    case assistantText(threadID: String, turnID: String, globalSequence: UInt64, delta: String)
    case runCompletion(threadID: String, turnID: String, globalSequence: UInt64, result: String, errorMessage: String)
    case threadCatchUpBatch(
        threadID: String,
        latestThreadSequence: UInt64,
        events: [CodexV2ThreadEvent],
        hasMore: Bool
    )
    case error(code: String, message: String, retryable: Bool)
}

struct CodexV2ResolvedConnection: Sendable {
    let daemonHealth: CodexV2DaemonHealthSnapshot
    let resolvedSession: CodexV2SessionResolveResponse
    let macDeviceID: String
    let phoneDeviceID: String
    let websocketURL: URL
}

struct CodexV2TimelineState: Sendable {
    var frames: [CodexV2ServerFrame]
    var threadSummaries: [CodexV2ThreadSummary]
    var latestThreadID: String?
    var didReceiveSessionReady: Bool
    var didReceiveThreadList: Bool
    var didReceiveRunCompletion: Bool
    var didReceiveCatchUpBatch: Bool

    init(
        frames: [CodexV2ServerFrame] = [],
        threadSummaries: [CodexV2ThreadSummary] = [],
        latestThreadID: String? = nil,
        didReceiveSessionReady: Bool = false,
        didReceiveThreadList: Bool = false,
        didReceiveRunCompletion: Bool = false,
        didReceiveCatchUpBatch: Bool = false
    ) {
        self.frames = frames
        self.threadSummaries = threadSummaries
        self.latestThreadID = latestThreadID
        self.didReceiveSessionReady = didReceiveSessionReady
        self.didReceiveThreadList = didReceiveThreadList
        self.didReceiveRunCompletion = didReceiveRunCompletion
        self.didReceiveCatchUpBatch = didReceiveCatchUpBatch
    }
}

struct CodexV2ProbeResult: Sendable {
    let daemonHealth: CodexV2DaemonHealthSnapshot
    let resolvedSession: CodexV2SessionResolveResponse
    let frames: [CodexV2ServerFrame]
}
