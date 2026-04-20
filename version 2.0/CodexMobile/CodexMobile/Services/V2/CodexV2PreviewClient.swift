// FILE: CodexV2PreviewClient.swift
// Purpose: Interactive Version 2.0 relay-backed client for the iOS app snapshot.
// Layer: Service
// Exports: CodexV2PreviewClient

import Foundation
import Observation

@MainActor
@Observable
final class CodexV2PreviewClient {
    private enum Defaults {
        static let relayHTTPBaseURLString = "http://127.0.0.1:9910"
        static let relayWSBaseURLString = "ws://127.0.0.1:9910"
        static let daemonHealthURLString = "http://127.0.0.1:9911/health"
        static let prompt = "Reply with a short V2 preview confirmation."
    }

    private enum StorageKey {
        static let relayHTTPBaseURLString = "codex.v2Preview.relayHTTPBaseURLString"
        static let relayWSBaseURLString = "codex.v2Preview.relayWSBaseURLString"
        static let daemonHealthURLString = "codex.v2Preview.daemonHealthURLString"
        static let macDeviceIDOverride = "codex.v2Preview.macDeviceIDOverride"
        static let prompt = "codex.v2Preview.prompt"
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
    private(set) var activeThreadID: String?
    private(set) var activeTurnID: String?
    private(set) var latestTurnID: String?

    private let urlSession: URLSession
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var currentConnection: CodexV2ResolvedConnection?
    @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveLoopTask: Task<Void, Never>?
    @ObservationIgnored private var didRequestDisconnect = false

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
    }

    func clear() {
        lastErrorMessage = nil
        timeline = CodexV2TimelineState()
        activeThreadID = nil
        activeTurnID = nil
        latestTurnID = nil
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

    func connect(resetTimeline: Bool = false) async {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        lastErrorMessage = nil
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

            startReceiveLoop(task: task)
            try await sendThreadListRequest(task: task)
        } catch {
            teardownConnection()
            lastErrorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        didRequestDisconnect = true
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        teardownConnection()
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

        do {
            try await sendRunStart(
                task: task,
                prompt: trimmedPrompt,
                threadID: timeline.latestThreadID ?? activeThreadID ?? ""
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
}

private extension CodexV2PreviewClient {
    func fetchDaemonHealth() async throws -> CodexV2DaemonHealthSnapshot {
        guard let daemonHealthURL = URL(
            string: daemonHealthURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await urlSession.data(from: daemonHealthURL)
        try validateHTTP(response)
        return try JSONDecoder().decode(CodexV2DaemonHealthSnapshot.self, from: data)
    }

    func resolveSession(
        relayHTTPBaseURL: URL,
        macDeviceID: String,
        phoneDeviceID: String
    ) async throws -> CodexV2SessionResolveResponse {
        let url = relayHTTPBaseURL.appending(path: "v2/session/resolve")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mac_device_id": macDeviceID,
            "phone_device_id": phoneDeviceID,
        ])

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response)
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
            throw URLError(.badURL)
        }

        let daemonHealth = try await fetchDaemonHealth()
        let resolvedMacDeviceID = macDeviceID ?? daemonHealth.macDeviceID
        let phoneDeviceID = "app-phone-\(UUID().uuidString)"
        let resolvedSession = try await resolveSession(
            relayHTTPBaseURL: relayHTTPBaseURL,
            macDeviceID: resolvedMacDeviceID,
            phoneDeviceID: phoneDeviceID
        )

        let websocketURL = relayWSBaseURL
            .appending(path: "v2/ws")
            .appending(path: resolvedSession.relaySessionID)
            .appending(queryItems: [
                URLQueryItem(name: "role", value: "phone"),
                URLQueryItem(name: "device_id", value: phoneDeviceID),
            ])

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
        timeline = apply(frame, to: timeline)

        switch frame {
        case let .runStarted(threadID, turnID, _, _):
            activeThreadID = threadID
            activeTurnID = turnID
            latestTurnID = turnID
            isRunning = true
        case let .runCompletion(threadID, turnID, _, _, _):
            activeThreadID = threadID
            activeTurnID = nil
            latestTurnID = turnID
            isRunning = false
            do {
                try await sendThreadCatchUp(task: task, threadID: threadID)
            } catch {
                handleTransportFailure(error)
            }
        case let .threadCatchUpBatch(threadID, _, _, _):
            activeThreadID = threadID
        case let .error(_, message, _):
            lastErrorMessage = message
        case .sessionReady, .threadListSnapshot, .reasoning, .assistantText:
            break
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
        case .threadListSnapshot:
            next.didReceiveThreadList = true
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
        teardownConnection()
    }

    func teardownConnection() {
        isConnecting = false
        isConnected = false
        isRunning = false
        activeTurnID = nil
        currentConnection = nil
        webSocketTask = nil
    }

    func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    var normalizedMacDeviceIDOverride: String? {
        let trimmed = macDeviceIDOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
}

private extension URLComponents {
    func withScheme(_ scheme: String) -> URLComponents {
        var copy = self
        copy.scheme = scheme
        return copy
    }
}
