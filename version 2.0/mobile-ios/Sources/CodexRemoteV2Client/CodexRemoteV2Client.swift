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

    public func runProbe(
        macDeviceID: String? = nil,
        prompt: String = "Create a placeholder remote run from Swift."
    ) async throws -> V2ProbeResult {
        let daemonHealth = try await fetchDaemonHealth()
        let resolvedMacDeviceID = macDeviceID ?? daemonHealth.macDeviceID
        let phoneDeviceID = "swift-phone-probe-\(UUID().uuidString)"
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

        let task = urlSession.webSocketTask(with: websocketURL)
        task.resume()

        try await task.send(.data(
            V2ProtoCodec.makeSessionResumeFrame(
                macDeviceID: resolvedMacDeviceID,
                phoneDeviceID: phoneDeviceID
            )
        ))
        try await task.send(.data(
            V2ProtoCodec.makeThreadListRequestFrame()
        ))

        var frames: [V2ServerFrame] = []
        var sentRunStart = false
        var sentCatchUp = false

        while true {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                let frame = try V2ProtoCodec.decodeServerFrame(data)
                frames.append(frame)

                if case .threadListSnapshot = frame, !sentRunStart {
                    sentRunStart = true
                    try await task.send(.data(
                        V2ProtoCodec.makeRunStartRequestFrame(text: prompt)
                    ))
                }

                if case let .runCompletion(threadID, _, _, _, _) = frame, !sentCatchUp {
                    sentCatchUp = true
                    try await task.send(.data(
                        V2ProtoCodec.makeThreadCatchUpRequestFrame(threadID: threadID)
                    ))
                }

                if case .threadCatchUpBatch = frame {
                    task.cancel(with: .normalClosure, reason: nil)
                    return V2ProbeResult(
                        daemonHealth: daemonHealth,
                        resolvedSession: resolvedSession,
                        frames: frames
                    )
                }
            case .string:
                continue
            @unknown default:
                continue
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
