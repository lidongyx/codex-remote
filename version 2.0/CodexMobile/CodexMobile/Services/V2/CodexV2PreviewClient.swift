// FILE: CodexV2PreviewClient.swift
// Purpose: Interactive Version 2.0 relay-backed client for the iOS app snapshot.
// Layer: Service
// Exports: CodexV2PreviewClient

import Foundation
import Observation

enum CodexV2PreviewClientError: LocalizedError {
    case invalidURL(String)
    case invalidHTTPResponse
    case unexpectedHTTPStatus(code: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return message
        case .invalidHTTPResponse:
            return "The V2 relay returned an invalid HTTP response."
        case .unexpectedHTTPStatus(let code, let body):
            if body.isEmpty {
                return "The V2 relay returned HTTP \(code)."
            }
            return "The V2 relay returned HTTP \(code): \(body)"
        }
    }
}

@MainActor
@Observable
final class CodexV2PreviewClient {
    private enum Defaults {
        static let relayHTTPBaseURLString = "http://127.0.0.1:9910"
        static let relayWSBaseURLString = "ws://127.0.0.1:9910"
        static let daemonHealthURLString = "http://127.0.0.1:9911/health"
        static let prompt = "Reply with a short V2 preview confirmation."
    }

    private enum ReconnectDefaults {
        static let backoffNanoseconds: [UInt64] = [
            800_000_000,
            1_600_000_000,
            3_000_000_000,
        ]
        static let sleepChunkNanoseconds: UInt64 = 200_000_000
    }

    private enum StorageKey {
        static let relayHTTPBaseURLString = "codex.v2Preview.relayHTTPBaseURLString"
        static let relayWSBaseURLString = "codex.v2Preview.relayWSBaseURLString"
        static let daemonHealthURLString = "codex.v2Preview.daemonHealthURLString"
        static let macDeviceIDOverride = "codex.v2Preview.macDeviceIDOverride"
        static let prompt = "codex.v2Preview.prompt"
        static let selectedThreadID = "codex.v2Preview.selectedThreadID"
    }

    var relayHTTPBaseURLString = Defaults.relayHTTPBaseURLString {
        didSet { persist(relayHTTPBaseURLString, forKey: StorageKey.relayHTTPBaseURLString) }
    }
    var relayWSBaseURLString = Defaults.relayWSBaseURLString {
        didSet { persist(relayWSBaseURLString, forKey: StorageKey.relayWSBaseURLString) }
    }
    var daemonHealthURLString = Defaults.daemonHealthURLString {
        didSet { persist(daemonHealthURLString, forKey: StorageKey.daemonHealthURLString) }
    }
    var macDeviceIDOverride = "" {
        didSet { persist(macDeviceIDOverride, forKey: StorageKey.macDeviceIDOverride) }
    }
    var prompt = Defaults.prompt {
        didSet { persist(prompt, forKey: StorageKey.prompt) }
    }

    private(set) var isConnecting = false
    private(set) var isConnected = false
    private(set) var isRunning = false
    private(set) var lastErrorMessage: String?
    private(set) var daemonHealth: CodexV2DaemonHealthSnapshot?
    private(set) var resolvedSession: CodexV2SessionResolveResponse?
    private(set) var timeline = CodexV2TimelineState()
    private(set) var conversationState = CodexV2ConversationState()
    private(set) var reconnectState: CodexV2ReconnectState = .idle
    private(set) var activeThreadID: String?
    private(set) var activeTurnID: String?
    private(set) var latestTurnID: String?
    private(set) var isRestoringSelectedThread = false
    private(set) var isStartingFreshConversation = false
    private(set) var selectedThreadID: String? {
        didSet {
            persist(selectedThreadID ?? "", forKey: StorageKey.selectedThreadID)
        }
    }

    private let urlSession: URLSession
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var currentConnection: CodexV2ResolvedConnection?
    @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveLoopTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var didRequestDisconnect = false
    @ObservationIgnored private var isAppInForeground = true

    init(
        urlSession: URLSession = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.urlSession = urlSession
        self.userDefaults = userDefaults
        relayHTTPBaseURLString = Self.storedValue(
            forKey: StorageKey.relayHTTPBaseURLString,
            defaultValue: Defaults.relayHTTPBaseURLString,
            userDefaults: userDefaults
        )
        relayWSBaseURLString = Self.storedValue(
            forKey: StorageKey.relayWSBaseURLString,
            defaultValue: Defaults.relayWSBaseURLString,
            userDefaults: userDefaults
        )
        daemonHealthURLString = Self.storedValue(
            forKey: StorageKey.daemonHealthURLString,
            defaultValue: Defaults.daemonHealthURLString,
            userDefaults: userDefaults
        )
        macDeviceIDOverride = Self.storedValue(
            forKey: StorageKey.macDeviceIDOverride,
            defaultValue: "",
            userDefaults: userDefaults
        )
        prompt = Self.storedValue(
            forKey: StorageKey.prompt,
            defaultValue: Defaults.prompt,
            userDefaults: userDefaults
        )
        let storedSelectedThreadID = Self.storedValue(
            forKey: StorageKey.selectedThreadID,
            defaultValue: "",
            userDefaults: userDefaults
        )
        selectedThreadID = storedSelectedThreadID.isEmpty ? nil : storedSelectedThreadID
    }

    var isReconnecting: Bool {
        reconnectState != .idle
    }

    var reconnectAttemptCount: Int {
        reconnectState.attemptCount
    }

    var displayedConversationThreadID: String? {
        if isStartingFreshConversation {
            return conversationState.messagesByThreadID[CodexV2ConversationReducer.pendingThreadKey]?.isEmpty == false
                ? CodexV2ConversationReducer.pendingThreadKey
                : nil
        }

        if let selectedThreadID = normalizedIdentifier(selectedThreadID) {
            return selectedThreadID
        }

        if let activeThreadID = normalizedIdentifier(activeThreadID) {
            return activeThreadID
        }

        if conversationState.messagesByThreadID[CodexV2ConversationReducer.pendingThreadKey]?.isEmpty == false {
            return CodexV2ConversationReducer.pendingThreadKey
        }

        return normalizedIdentifier(timeline.latestThreadID)
    }

    var currentConversationItems: [CodexV2ConversationItem] {
        guard let displayedConversationThreadID else {
            return []
        }

        return conversationState.messagesByThreadID[displayedConversationThreadID] ?? []
    }

    var selectedThreadSummary: CodexV2ThreadSummary? {
        guard let selectedThreadID = normalizedIdentifier(selectedThreadID) else {
            return nil
        }

        return timeline.threadSummaries.first(where: { $0.threadID == selectedThreadID })
    }

    var displayedThreadRecoverySnapshot: CodexV2ThreadRecoverySnapshot? {
        guard let displayedConversationThreadID,
              displayedConversationThreadID != CodexV2ConversationReducer.pendingThreadKey else {
            return nil
        }

        return conversationState.recoveryByThreadID[displayedConversationThreadID]
    }

    func clear() {
        cancelReconnectLoop()
        lastErrorMessage = nil
        timeline = CodexV2TimelineState()
        conversationState = CodexV2ConversationState()
        reconnectState = .idle
        activeThreadID = nil
        activeTurnID = nil
        latestTurnID = nil
        isRestoringSelectedThread = false
        isStartingFreshConversation = false
        selectedThreadID = nil
    }

    func resetConnectionFieldsToLocalDefaults() {
        relayHTTPBaseURLString = Defaults.relayHTTPBaseURLString
        relayWSBaseURLString = Defaults.relayWSBaseURLString
        daemonHealthURLString = Defaults.daemonHealthURLString
        macDeviceIDOverride = ""
    }

    func applySuggestedConnection(
        relayURLString: String?,
        macDeviceID: String?
    ) {
        if let derivedBaseURLs = Self.derivedRelayBaseURLs(from: relayURLString) {
            relayHTTPBaseURLString = derivedBaseURLs.http
            relayWSBaseURLString = derivedBaseURLs.ws
        }

        macDeviceIDOverride = macDeviceID ?? ""
    }

    func setForegroundActive(_ isForeground: Bool) {
        isAppInForeground = isForeground

        guard isForeground,
              isReconnecting,
              !isConnected,
              !isConnecting else {
            return
        }

        ensureReconnectLoop()
    }

    func newConversation() {
        isStartingFreshConversation = true
        isRestoringSelectedThread = false
        selectedThreadID = nil
        activeThreadID = nil
        activeTurnID = nil
        isRunning = false
        lastErrorMessage = nil
    }

    func connect(resetTimeline: Bool = false) async {
        cancelReconnectLoop()
        await connect(resetTimeline: resetTimeline, isRecoveryAttempt: false)
    }

    private func connect(
        resetTimeline: Bool,
        isRecoveryAttempt: Bool
    ) async {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        if !isRecoveryAttempt {
            lastErrorMessage = nil
        }
        didRequestDisconnect = false

        if resetTimeline {
            clear()
        }

        defer { isConnecting = false }

        do {
            let connection = try await resolveConnection(macDeviceID: normalizedMacDeviceIDOverride)
            let task = openSession(connection: connection)
            try await sendSessionResume(task: task, connection: connection)

            daemonHealth = connection.daemonHealth
            resolvedSession = connection.resolvedSession
            currentConnection = connection
            webSocketTask = task
            isConnected = true
            reconnectState = .idle
            reconnectTask = nil
            if !isStartingFreshConversation,
               normalizedIdentifier(selectedThreadID) != nil || normalizedIdentifier(activeThreadID) != nil {
                isRestoringSelectedThread = true
            }

            startReceiveLoop(task: task)
            try await sendThreadListRequest(task: task)
        } catch {
            teardownConnection(preserveRunState: isRecoveryAttempt)
            lastErrorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        didRequestDisconnect = true
        cancelReconnectLoop()
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        teardownConnection(preserveRunState: false)
    }

    func refreshThreads() async {
        guard let task = webSocketTask, isConnected else {
            await connect()
            return
        }

        do {
            try await sendThreadListRequest(task: task)
        } catch {
            handleTransportFailure(error)
        }
    }

    func selectThread(_ threadID: String) async {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return }

        isStartingFreshConversation = false
        isRestoringSelectedThread = true
        lastErrorMessage = nil
        selectedThreadID = normalizedThreadID
        activeThreadID = normalizedThreadID

        guard let task = webSocketTask, isConnected else {
            return
        }

        do {
            let sinceThreadSequence = catchUpStartSequence(for: normalizedThreadID)
            try await sendThreadCatchUp(
                task: task,
                threadID: normalizedThreadID,
                sinceThreadSequence: sinceThreadSequence
            )
        } catch {
            handleTransportFailure(error)
        }
    }

    func sendPrompt() async {
        if !isConnected {
            await connect()
        }

        guard let task = webSocketTask, isConnected else {
            return
        }

        guard !isRunning else {
            return
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            lastErrorMessage = "Prompt cannot be empty."
            return
        }

        lastErrorMessage = nil
        timeline.didReceiveRunCompletion = false
        timeline.didReceiveCatchUpBatch = false
        let targetThreadID = isStartingFreshConversation
            ? ""
            : (selectedThreadID ?? timeline.latestThreadID ?? activeThreadID ?? "")
        let provisionalThreadID = normalizedIdentifier(targetThreadID)
        _ = CodexV2ConversationReducer.recordOutgoingPrompt(
            trimmedPrompt,
            provisionalThreadID: provisionalThreadID,
            in: &conversationState
        )

        do {
            try await sendRunStart(
                task: task,
                prompt: trimmedPrompt,
                threadID: targetThreadID
            )
        } catch {
            handleTransportFailure(error)
        }
    }

    func interruptCurrentRun() async {
        guard let task = webSocketTask,
              let threadID = activeThreadID,
              let turnID = activeTurnID else {
            return
        }

        do {
            try await sendRunInterrupt(task: task, threadID: threadID, turnID: turnID)
        } catch {
            handleTransportFailure(error)
        }
    }

    @discardableResult
    func applyFrameLocally(_ frame: CodexV2ServerFrame) -> String? {
        timeline = apply(frame, to: timeline)
        CodexV2ConversationReducer.apply(frame, to: &conversationState)

        switch frame {
        case let .runStarted(threadID, turnID, _, _):
            activeThreadID = threadID
            selectedThreadID = threadID
            activeTurnID = turnID
            latestTurnID = turnID
            isRunning = true
            isStartingFreshConversation = false
            return nil
        case let .runCompletion(threadID, turnID, _, _, _):
            activeThreadID = threadID
            selectedThreadID = threadID
            activeTurnID = nil
            latestTurnID = turnID
            isRunning = false
            return nil
        case let .threadCatchUpBatch(threadID, _, _, hasMore):
            activeThreadID = threadID
            if normalizedIdentifier(selectedThreadID) == threadID {
                isRestoringSelectedThread = hasMore
            }
            return hasMore ? threadID : nil
        case let .error(code, message, _):
            lastErrorMessage = message
            CodexV2ConversationReducer.appendTransportError(
                code: code,
                message: message,
                threadID: selectedThreadID ?? activeThreadID,
                in: &conversationState
            )
            return nil
        case let .threadListSnapshot(_, threads):
            if let currentSelectedThreadID = normalizedIdentifier(selectedThreadID),
               !threads.contains(where: { $0.threadID == currentSelectedThreadID }) {
                selectedThreadID = nil
            }

            if !isStartingFreshConversation,
               normalizedIdentifier(selectedThreadID) == nil {
                selectedThreadID = threads.first?.threadID
            }

            let referenceThreadID = normalizedIdentifier(selectedThreadID)
                ?? normalizedIdentifier(activeThreadID)
            if let referenceThreadID,
               let referenceThread = threads.first(where: { $0.threadID == referenceThreadID }) {
                isRunning = referenceThread.isRunning
                if !referenceThread.isRunning {
                    activeTurnID = nil
                }
            } else if !threads.contains(where: { $0.isRunning }) {
                isRunning = false
                activeTurnID = nil
            }

            if let selectedThreadID = normalizedIdentifier(selectedThreadID),
               threads.contains(where: { $0.threadID == selectedThreadID }),
               shouldRequestCatchUpAfterThreadList(for: selectedThreadID) {
                isRestoringSelectedThread = true
                return selectedThreadID
            }
            return nil
        case .sessionReady, .reasoning, .assistantText:
            return nil
        }
    }
}

private extension CodexV2PreviewClient {
    func fetchDaemonHealth() async throws -> CodexV2DaemonHealthSnapshot {
        guard let daemonHealthURL = URL(
            string: daemonHealthURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw CodexV2PreviewClientError.invalidURL("The daemon health URL is invalid.")
        }

        let (data, response) = try await urlSession.data(from: daemonHealthURL)
        try validateHTTP(response, data: data)
        return try JSONDecoder().decode(CodexV2DaemonHealthSnapshot.self, from: data)
    }

    func resolveSession(
        relayHTTPBaseURL: URL,
        macDeviceID: String,
        phoneDeviceID: String
    ) async throws -> CodexV2SessionResolveResponse {
        let url = try appendingPathSegments(["v2", "session", "resolve"], to: relayHTTPBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mac_device_id": macDeviceID,
            "phone_device_id": phoneDeviceID,
        ])

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response, data: data)
        return try JSONDecoder().decode(CodexV2SessionResolveResponse.self, from: data)
    }

    func resolveConnection(
        macDeviceID: String? = nil
    ) async throws -> CodexV2ResolvedConnection {
        guard let relayHTTPBaseURL = URL(
            string: relayHTTPBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        let relayWSBaseURL = URL(
            string: relayWSBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw CodexV2PreviewClientError.invalidURL("The relay base URLs are invalid.")
        }

        let daemonHealth = try await fetchDaemonHealth()
        let resolvedMacDeviceID = macDeviceID ?? daemonHealth.macDeviceID
        let phoneDeviceID = "app-phone-\(UUID().uuidString)"
        let resolvedSession = try await resolveSession(
            relayHTTPBaseURL: relayHTTPBaseURL,
            macDeviceID: resolvedMacDeviceID,
            phoneDeviceID: phoneDeviceID
        )

        let websocketURL = try makeRelayWebSocketURL(
            baseURL: relayWSBaseURL,
            sessionID: resolvedSession.relaySessionID,
            phoneDeviceID: phoneDeviceID
        )

        return CodexV2ResolvedConnection(
            daemonHealth: daemonHealth,
            resolvedSession: resolvedSession,
            macDeviceID: resolvedMacDeviceID,
            phoneDeviceID: phoneDeviceID,
            websocketURL: websocketURL
        )
    }

    func openSession(connection: CodexV2ResolvedConnection) -> URLSessionWebSocketTask {
        let task = urlSession.webSocketTask(with: connection.websocketURL)
        task.resume()
        return task
    }

    func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                while !Task.isCancelled, self.webSocketTask === task {
                    guard let frame = try await self.receiveFrame(task: task) else {
                        continue
                    }
                    await self.handle(frame: frame, task: task)
                }
            } catch {
                guard !Task.isCancelled, !didRequestDisconnect else {
                    return
                }
                handleTransportFailure(error)
            }
        }
    }

    func handle(frame: CodexV2ServerFrame, task: URLSessionWebSocketTask) async {
        if let threadIDToCatchUp = applyFrameLocally(frame) {
            do {
                try await sendThreadCatchUp(
                    task: task,
                    threadID: threadIDToCatchUp,
                    sinceThreadSequence: catchUpStartSequence(for: threadIDToCatchUp)
                )
            } catch {
                handleTransportFailure(error)
            }
        }
    }

    func sendSessionResume(
        task: URLSessionWebSocketTask,
        connection: CodexV2ResolvedConnection
    ) async throws {
        try await task.send(.data(
            CodexV2PreviewProtoCodec.makeSessionResumeFrame(
                macDeviceID: connection.macDeviceID,
                phoneDeviceID: connection.phoneDeviceID
            )
        ))
    }

    func sendThreadListRequest(
        task: URLSessionWebSocketTask,
        sinceGlobalSequence: UInt64 = 0
    ) async throws {
        try await task.send(.data(
            CodexV2PreviewProtoCodec.makeThreadListRequestFrame(
                sinceGlobalSequence: sinceGlobalSequence
            )
        ))
    }

    func sendRunStart(
        task: URLSessionWebSocketTask,
        prompt: String,
        threadID: String = ""
    ) async throws {
        try await task.send(.data(
            CodexV2PreviewProtoCodec.makeRunStartRequestFrame(
                threadID: threadID,
                text: prompt
            )
        ))
    }

    func sendRunInterrupt(
        task: URLSessionWebSocketTask,
        threadID: String,
        turnID: String
    ) async throws {
        try await task.send(.data(
            CodexV2PreviewProtoCodec.makeRunInterruptRequestFrame(
                threadID: threadID,
                turnID: turnID
            )
        ))
    }

    func sendThreadCatchUp(
        task: URLSessionWebSocketTask,
        threadID: String,
        sinceThreadSequence: UInt64 = 0
    ) async throws {
        try await task.send(.data(
            CodexV2PreviewProtoCodec.makeThreadCatchUpRequestFrame(
                threadID: threadID,
                sinceThreadSequence: sinceThreadSequence
            )
        ))
    }

    func receiveFrame(task: URLSessionWebSocketTask) async throws -> CodexV2ServerFrame? {
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return try CodexV2PreviewProtoCodec.decodeServerFrame(data)
        case .string:
            return nil
        @unknown default:
            return nil
        }
    }

    func apply(
        _ frame: CodexV2ServerFrame,
        to state: CodexV2TimelineState
    ) -> CodexV2TimelineState {
        var next = state
        next.frames.append(frame)

        switch frame {
        case .sessionReady:
            next.didReceiveSessionReady = true
        case let .threadListSnapshot(_, threads):
            next.didReceiveThreadList = true
            next.threadSummaries = threads
            if next.latestThreadID == nil {
                next.latestThreadID = threads.first?.threadID
            }
        case let .runStarted(threadID, _, _, _):
            next.latestThreadID = threadID
            next.didReceiveRunCompletion = false
            next.didReceiveCatchUpBatch = false
        case .runCompletion:
            next.didReceiveRunCompletion = true
        case let .threadCatchUpBatch(threadID, _, _, _):
            next.latestThreadID = threadID
            next.didReceiveCatchUpBatch = true
        case .reasoning, .assistantText, .error:
            break
        }

        return next
    }

    func handleTransportFailure(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        teardownConnection(preserveRunState: true)
        guard !didRequestDisconnect else {
            return
        }
        isRestoringSelectedThread = normalizedIdentifier(selectedThreadID) != nil
            || normalizedIdentifier(activeThreadID) != nil
        ensureReconnectLoop()
    }

    func teardownConnection(preserveRunState: Bool) {
        isConnecting = false
        isConnected = false
        if !preserveRunState {
            isRunning = false
            activeTurnID = nil
            isRestoringSelectedThread = false
        }
        currentConnection = nil
        webSocketTask = nil
    }

    func ensureReconnectLoop() {
        guard reconnectTask == nil else {
            return
        }

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.reconnectTask = nil
            }

            var attempt = 0

            while !Task.isCancelled,
                  !didRequestDisconnect,
                  !isConnected {
                attempt += 1
                reconnectState = .reconnecting(attempt: attempt)

                let backoff = reconnectBackoffNanoseconds(
                    attempt: attempt
                )
                await sleepForReconnectBackoff(backoff)

                guard !Task.isCancelled,
                      !didRequestDisconnect,
                      isAppInForeground,
                      !isConnected else {
                    continue
                }

                await connect(resetTimeline: false, isRecoveryAttempt: true)
            }

            if !didRequestDisconnect, isConnected {
                reconnectState = .idle
            }
        }
    }

    func cancelReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectState = .idle
    }

    func reconnectBackoffNanoseconds(attempt: Int) -> UInt64 {
        let index = max(0, min(attempt - 1, ReconnectDefaults.backoffNanoseconds.count - 1))
        return ReconnectDefaults.backoffNanoseconds[index]
    }

    func sleepForReconnectBackoff(_ durationNanoseconds: UInt64) async {
        var remaining = durationNanoseconds

        while remaining > 0 {
            if Task.isCancelled || didRequestDisconnect {
                return
            }

            if !isAppInForeground {
                try? await Task.sleep(nanoseconds: ReconnectDefaults.sleepChunkNanoseconds)
                continue
            }

            let chunk = min(remaining, ReconnectDefaults.sleepChunkNanoseconds)
            try? await Task.sleep(nanoseconds: chunk)
            remaining -= chunk
        }
    }

    func validateHTTP(_ response: URLResponse) throws {
        try validateHTTP(response, data: nil)
    }

    func catchUpStartSequence(for threadID: String) -> UInt64 {
        let normalizedThreadID = normalizedThreadKey(threadID)
        return conversationState.recoveryByThreadID[normalizedThreadID]?.latestThreadSequence ?? 0
    }

    func shouldRequestCatchUpAfterThreadList(for threadID: String) -> Bool {
        guard !isStartingFreshConversation else {
            return false
        }

        if isRestoringSelectedThread {
            return true
        }

        let normalizedThreadID = normalizedThreadKey(threadID)
        let hasMessages = !(conversationState.messagesByThreadID[normalizedThreadID]?.isEmpty ?? true)
        let hasRecoverySnapshot = conversationState.recoveryByThreadID[normalizedThreadID] != nil
        return !hasMessages || !hasRecoverySnapshot
    }

    func validateHTTP(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CodexV2PreviewClientError.invalidHTTPResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { data in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            throw CodexV2PreviewClientError.unexpectedHTTPStatus(
                code: http.statusCode,
                body: body
            )
        }
    }

    var normalizedMacDeviceIDOverride: String? {
        normalizedIdentifier(macDeviceIDOverride)
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedThreadKey(_ threadID: String) -> String {
        CodexV2ConversationReducer.normalizedThreadKey(threadID)
    }

    func persist(_ value: String, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }

    static func storedValue(
        forKey key: String,
        defaultValue: String,
        userDefaults: UserDefaults
    ) -> String {
        guard let stored = userDefaults.string(forKey: key) else {
            return defaultValue
        }
        return stored
    }

    static func derivedRelayBaseURLs(from relayURLString: String?) -> (http: String, ws: String)? {
        guard let relayURLString = relayURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !relayURLString.isEmpty,
              var components = URLComponents(string: relayURLString) else {
            return nil
        }

        components = relayBaseComponents(from: components)
        guard let httpURL = components.withScheme(httpScheme(for: components.scheme)).url?.absoluteString,
              let wsURL = components.withScheme(wsScheme(for: components.scheme)).url?.absoluteString else {
            return nil
        }

        return (httpURL, wsURL)
    }

    static func relayBaseComponents(from components: URLComponents) -> URLComponents {
        var copy = components
        let pathComponents = copy.path.split(separator: "/").map(String.init)
        if pathComponents.last == "relay" {
            let prefix = pathComponents.dropLast()
            copy.path = prefix.isEmpty ? "" : "/" + prefix.joined(separator: "/")
        }
        return copy
    }

    static func httpScheme(for scheme: String?) -> String {
        switch scheme?.lowercased() {
        case "wss", "https":
            return "https"
        default:
            return "http"
        }
    }

    static func wsScheme(for scheme: String?) -> String {
        switch scheme?.lowercased() {
        case "https", "wss":
            return "wss"
        default:
            return "ws"
        }
    }

    func appendingPathSegments(_ segments: [String], to baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CodexV2PreviewClientError.invalidURL("The relay URL could not be parsed.")
        }

        let baseSegments = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        let mergedSegments = baseSegments + segments
        components.path = "/" + mergedSegments.joined(separator: "/")
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw CodexV2PreviewClientError.invalidURL("The relay URL could not be built.")
        }

        return url
    }

    func makeRelayWebSocketURL(
        baseURL: URL,
        sessionID: String,
        phoneDeviceID: String
    ) throws -> URL {
        let sessionURL = try appendingPathSegments(["v2", "ws", sessionID], to: baseURL)
        guard var components = URLComponents(url: sessionURL, resolvingAgainstBaseURL: false) else {
            throw CodexV2PreviewClientError.invalidURL("The V2 websocket URL could not be parsed.")
        }

        components.queryItems = [
            URLQueryItem(name: "role", value: "phone"),
            URLQueryItem(name: "device_id", value: phoneDeviceID),
        ]

        guard let url = components.url else {
            throw CodexV2PreviewClientError.invalidURL("The V2 websocket URL could not be built.")
        }

        return url
    }
}

private extension URLComponents {
    func withScheme(_ scheme: String) -> URLComponents {
        var copy = self
        copy.scheme = scheme
        return copy
    }
}
