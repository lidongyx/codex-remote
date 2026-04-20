import CodexRemoteV2Client
import Foundation

@main
struct CodexRemoteV2ClientDemo {
    static func main() async {
        let relayHTTPBaseURL = URL(string: ProcessInfo.processInfo.environment["RELAY_HTTP_URL"] ?? "http://127.0.0.1:9910")!
        let relayWSBaseURL = URL(string: ProcessInfo.processInfo.environment["RELAY_WS_BASE_URL"] ?? "ws://127.0.0.1:9910")!
        let daemonHealthURL = URL(string: ProcessInfo.processInfo.environment["DAEMON_HEALTH_URL"] ?? "http://127.0.0.1:9911/health")!
        let prompt = ProcessInfo.processInfo.environment["PROBE_PROMPT"] ?? "Create a placeholder remote run from Swift."
        let macDeviceID = CommandLine.arguments.dropFirst().first

        let client = CodexRemoteV2Client(
            relayHTTPBaseURL: relayHTTPBaseURL,
            relayWSBaseURL: relayWSBaseURL,
            daemonHealthURL: daemonHealthURL
        )

        do {
            let result = try await client.runProbe(macDeviceID: macDeviceID, prompt: prompt)
            print(jsonLine([
                "type": "daemon_health",
                "macDeviceId": result.daemonHealth.macDeviceID,
                "machineName": result.daemonHealth.machineName,
                "relayConnected": result.daemonHealth.relayConnected,
                "activeSessions": result.daemonHealth.activeSessions,
            ]))

            print(jsonLine([
                "type": "session_resolve",
                "relaySessionId": result.resolvedSession.relaySessionID,
                "machineName": result.resolvedSession.machineName,
                "routeCandidateCount": result.resolvedSession.routeCandidates.count,
            ]))

            for frame in result.frames {
                print(jsonLine(frame.asJSON))
            }
        } catch {
            fputs("swift V2 probe failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

private extension V2ServerFrame {
    var asJSON: [String: Any] {
        switch self {
        case let .sessionReady(sessionID, connectionMode, globalSequence):
            return [
                "type": "session_ready",
                "sessionId": sessionID,
                "connectionMode": connectionMode,
                "globalSequence": globalSequence,
            ]
        case let .threadListSnapshot(globalSequence, threadCount):
            return [
                "type": "thread_list_snapshot",
                "globalSequence": globalSequence,
                "threadCount": threadCount,
            ]
        case let .runStarted(threadID, turnID, globalSequence, model):
            return [
                "type": "run_started",
                "threadId": threadID,
                "turnId": turnID,
                "globalSequence": globalSequence,
                "model": model,
            ]
        case let .reasoning(threadID, turnID, globalSequence, itemID, delta):
            return [
                "type": "reasoning",
                "threadId": threadID,
                "turnId": turnID,
                "globalSequence": globalSequence,
                "itemId": itemID,
                "delta": delta,
            ]
        case let .assistantText(threadID, turnID, globalSequence, delta):
            return [
                "type": "assistant_text",
                "threadId": threadID,
                "turnId": turnID,
                "globalSequence": globalSequence,
                "delta": delta,
            ]
        case let .runCompletion(threadID, turnID, globalSequence, result, errorMessage):
            return [
                "type": "run_completion",
                "threadId": threadID,
                "turnId": turnID,
                "globalSequence": globalSequence,
                "result": result,
                "errorMessage": errorMessage,
            ]
        case let .error(code, message, retryable):
            return [
                "type": "error",
                "code": code,
                "message": message,
                "retryable": retryable,
            ]
        }
    }
}
