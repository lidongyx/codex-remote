import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class CodexRemoteV2Client {
    private let relayHTTPBaseURL: URL
    private let relayWSBaseURL: URL
    private let daemonHealthURL: URL
    private let urlSession: URLSession

    public init(
        relayHTTPBaseURL: URL,
        relayWSBaseURL: URL,
        daemonHealthURL: URL,
        urlSession: URLSession = .shared
    ) {
        self.relayHTTPBaseURL = relayHTTPBaseURL
        self.relayWSBaseURL = relayWSBaseURL
        self.daemonHealthURL = daemonHealthURL
        self.urlSession = urlSession
    }

    public func fetchDaemonHealth() async throws -> V2DaemonHealthSnapshot {
        let (data, response) = try await urlSession.data(from: daemonHealthURL)
        try validateHTTP(response)
        return try JSONDecoder().decode(V2DaemonHealthSnapshot.self, from: data)
    }

    public func resolveSession(
        macDeviceID: String,
        phoneDeviceID: String
    ) async throws -> V2SessionResolveResponse {
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
        return try JSONDecoder().decode(V2SessionResolveResponse.self, from: data)
    }

    public func resolveConnection(
        macDeviceID: String? = nil
    ) async throws -> V2ResolvedConnection {
        let daemonHealth = try await fetchDaemonHealth()
        let resolvedMacDeviceID = macDeviceID ?? daemonHealth.macDeviceID
        let phoneDeviceID = "swift-phone-\(UUID().uuidString)"
        let resolvedSession = try await resolveSession(
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

        return V2ResolvedConnection(
            daemonHealth: daemonHealth,
            resolvedSession: resolvedSession,
            macDeviceID: resolvedMacDeviceID,
            phoneDeviceID: phoneDeviceID,
            websocketURL: websocketURL
        )
    }

    public func openSession(
        connection: V2ResolvedConnection
    ) -> URLSessionWebSocketTask {
        let task = urlSession.webSocketTask(with: connection.websocketURL)
        task.resume()
        return task
    }

    public func sendSessionResume(
        task: URLSessionWebSocketTask,
        connection: V2ResolvedConnection
    ) async throws {
        try await task.send(.data(
            V2ProtoCodec.makeSessionResumeFrame(
                macDeviceID: connection.macDeviceID,
                phoneDeviceID: connection.phoneDeviceID
            )
        ))
    }

    public func sendThreadListRequest(
        task: URLSessionWebSocketTask,
        sinceGlobalSequence: UInt64 = 0
    ) async throws {
        try await task.send(.data(
            V2ProtoCodec.makeThreadListRequestFrame(sinceGlobalSequence: sinceGlobalSequence)
        ))
    }

    public func sendRunStart(
        task: URLSessionWebSocketTask,
        prompt: String,
        threadID: String = ""
    ) async throws {
        try await task.send(.data(
            V2ProtoCodec.makeRunStartRequestFrame(threadID: threadID, text: prompt)
        ))
    }

    public func sendThreadCatchUp(
        task: URLSessionWebSocketTask,
        threadID: String,
        sinceThreadSequence: UInt64 = 0
    ) async throws {
        try await task.send(.data(
            V2ProtoCodec.makeThreadCatchUpRequestFrame(
                threadID: threadID,
                sinceThreadSequence: sinceThreadSequence
            )
        ))
    }

    public func receiveFrame(
        task: URLSessionWebSocketTask
    ) async throws -> V2ServerFrame? {
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return try V2ProtoCodec.decodeServerFrame(data)
        case .string:
            return nil
        @unknown default:
            return nil
        }
    }

    public func apply(
        _ frame: V2ServerFrame,
        to state: V2TimelineState
    ) -> V2TimelineState {
        var next = state
        next.frames.append(frame)

        switch frame {
        case .sessionReady:
            next.didReceiveSessionReady = true
        case .threadListSnapshot:
            next.didReceiveThreadList = true
        case let .runStarted(threadID, _, _, _):
            next.latestThreadID = threadID
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

    public func runProbe(
        macDeviceID: String? = nil,
        prompt: String = "Create a placeholder remote run from Swift."
    ) async throws -> V2ProbeResult {
        let connection = try await resolveConnection(macDeviceID: macDeviceID)
        let task = openSession(connection: connection)
        try await sendSessionResume(task: task, connection: connection)
        try await sendThreadListRequest(task: task)

        var timeline = V2TimelineState()
        var sentRunStart = false
        var sentCatchUp = false

        while true {
            if let frame = try await receiveFrame(task: task) {
                timeline = apply(frame, to: timeline)

                if case .threadListSnapshot = frame, !sentRunStart {
                    sentRunStart = true
                    try await sendRunStart(task: task, prompt: prompt)
                }

                if case let .runCompletion(threadID, _, _, _, _) = frame, !sentCatchUp {
                    sentCatchUp = true
                    try await sendThreadCatchUp(task: task, threadID: threadID)
                }

                if case .threadCatchUpBatch = frame {
                    task.cancel(with: .normalClosure, reason: nil)
                    return V2ProbeResult(
                        daemonHealth: connection.daemonHealth,
                        resolvedSession: connection.resolvedSession,
                        frames: timeline.frames
                    )
                }
            }
        }
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
