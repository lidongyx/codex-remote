// FILE: CodexV2DebugView.swift
// Purpose: Minimal in-app debug surface for the Version 2.0 transport preview.
// Layer: View
// Exports: CodexV2DebugView

import SwiftUI

struct CodexV2DebugView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.dismiss) private var dismiss
    @State private var client = CodexV2PreviewClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    connectionCard
                    statusCard
                    framesCard
                }
                .padding()
            }
            .font(AppFont.body())
            .navigationTitle("Version 2.0 Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectionCard: some View {
        SettingsCard(title: "V2 Connection") {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                TrustedPairSummaryView(presentation: trustedPairPresentation)
            }

            if savedPairRelayURL != nil || savedPairDeviceID != nil {
                SettingsButton("Use Saved Pair") {
                    client.applySuggestedConnection(
                        relayURLString: savedPairRelayURL,
                        macDeviceID: savedPairDeviceID
                    )
                }

                Text("Derives the V2 relay host from the current local pairing. The V2 relay and daemon must be available on that same origin.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            SettingsButton("Use Local V2 Demo") {
                client.resetConnectionFieldsToLocalDefaults()
            }

            TextField("Relay HTTP URL", text: $client.relayHTTPBaseURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.mono(.caption))

            TextField("Relay WS URL", text: $client.relayWSBaseURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.mono(.caption))

            TextField("Daemon Health URL", text: $client.daemonHealthURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.mono(.caption))

            TextField("Mac Device ID Override", text: $client.macDeviceIDOverride)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.mono(.caption))

            TextField("Probe Prompt", text: $client.prompt, axis: .vertical)
                .lineLimit(2...5)

            SettingsButton(client.isRunning ? "Running..." : "Run Probe", isLoading: client.isRunning) {
                Task { @MainActor in
                    await client.runProbe()
                }
            }

            SettingsButton("Clear") {
                client.clear()
            }
        }
    }

    private var statusCard: some View {
        SettingsCard(title: "Status") {
            if let daemonHealth = client.daemonHealth {
                settingsRow("Mac Device ID", daemonHealth.macDeviceID)
                settingsRow("Machine", daemonHealth.machineName)
                if let runtimeMode = daemonHealth.runtimeMode, !runtimeMode.isEmpty {
                    settingsRow("Runtime", runtimeMode)
                }
                if let configuredModel = daemonHealth.configuredModel, !configuredModel.isEmpty {
                    settingsRow("Model", configuredModel)
                }
                settingsRow("Relay Configured", daemonHealth.relayConfigured ? "Yes" : "No")
                settingsRow("Relay", daemonHealth.relayConnected ? "Connected" : "Disconnected")
                settingsRow("Active Sessions", String(daemonHealth.activeSessions))

                if let workspaceRoot = daemonHealth.workspaceRoot, !workspaceRoot.isEmpty {
                    settingsRow("Workspace", workspaceRoot)
                }
            } else {
                Text("No daemon snapshot yet.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let resolvedSession = client.resolvedSession {
                Divider()
                settingsRow("Relay Session", resolvedSession.relaySessionID)
                settingsRow("Daemon Version", resolvedSession.daemonVersion)
                settingsRow("Route Candidates", String(resolvedSession.routeCandidates.count))

                if !resolvedSession.routeCandidates.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(resolvedSession.routeCandidates.enumerated()), id: \.offset) { _, route in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(route.kind) · priority \(route.priority)")
                                    .font(AppFont.subheadline(weight: .medium))
                                Text(route.address)
                                    .font(AppFont.mono(.caption))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            Divider()
            settingsRow("Session Ready", yesNo(client.timeline.didReceiveSessionReady))
            settingsRow("Thread List", yesNo(client.timeline.didReceiveThreadList))
            settingsRow("Run Completion", yesNo(client.timeline.didReceiveRunCompletion))
            settingsRow("Catch-up", yesNo(client.timeline.didReceiveCatchUpBatch))

            if let error = client.lastErrorMessage, !error.isEmpty {
                Divider()
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
            }
        }
    }

    private var framesCard: some View {
        SettingsCard(title: "Timeline") {
            if client.timeline.frames.isEmpty {
                Text("No V2 frames yet.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(client.timeline.frames.enumerated()), id: \.offset) { index, frame in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(frame.title)
                            .font(AppFont.subheadline(weight: .semibold))
                        Text(frame.subtitle)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)

                    if index != client.timeline.frames.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func settingsRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            Text(value)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private var savedPairRelayURL: String? {
        codex.preferredWakeRelayURL ?? codex.normalizedRelayURL
    }

    private var savedPairDeviceID: String? {
        codex.trustedPairPresentation?.deviceId
            ?? codex.normalizedRelayMacDeviceId
            ?? codex.normalizedLastTrustedMacDeviceId
    }
}

private extension CodexV2ServerFrame {
    var title: String {
        switch self {
        case .sessionReady:
            return "Session Ready"
        case .threadListSnapshot:
            return "Thread List"
        case .runStarted:
            return "Run Started"
        case .reasoning:
            return "Reasoning"
        case .assistantText:
            return "Assistant Text"
        case .runCompletion:
            return "Run Completion"
        case .threadCatchUpBatch:
            return "Thread Catch-up"
        case .error:
            return "Error"
        }
    }

    var subtitle: String {
        switch self {
        case let .sessionReady(sessionID, connectionMode, globalSequence):
            return "session=\(sessionID)\nmode=\(connectionMode)\nglobalSequence=\(globalSequence)"
        case let .threadListSnapshot(globalSequence, threadCount):
            return "globalSequence=\(globalSequence)\nthreadCount=\(threadCount)"
        case let .runStarted(threadID, turnID, globalSequence, model):
            return "thread=\(threadID)\nturn=\(turnID)\nsequence=\(globalSequence)\nmodel=\(model)"
        case let .reasoning(threadID, turnID, globalSequence, itemID, delta):
            return "thread=\(threadID)\nturn=\(turnID)\nsequence=\(globalSequence)\nitem=\(itemID)\n\(delta)"
        case let .assistantText(threadID, turnID, globalSequence, delta):
            return "thread=\(threadID)\nturn=\(turnID)\nsequence=\(globalSequence)\n\(delta)"
        case let .runCompletion(threadID, turnID, globalSequence, result, errorMessage):
            return "thread=\(threadID)\nturn=\(turnID)\nsequence=\(globalSequence)\nresult=\(result)\nerror=\(errorMessage)"
        case let .threadCatchUpBatch(threadID, latestThreadSequence, eventCount, hasMore):
            return "thread=\(threadID)\nlatestThreadSequence=\(latestThreadSequence)\neventCount=\(eventCount)\nhasMore=\(hasMore)"
        case let .error(code, message, retryable):
            return "code=\(code)\nretryable=\(retryable)\n\(message)"
        }
    }
}
