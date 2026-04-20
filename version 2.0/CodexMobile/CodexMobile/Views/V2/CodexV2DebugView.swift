// FILE: CodexV2DebugView.swift
// Purpose: Minimal in-app debug surface for the Version 2.0 transport preview.
// Layer: View
// Exports: CodexV2DebugView

import SwiftUI

struct CodexV2DebugView: View {
    @Environment(CodexService.self) private var codex
    @Environment(CodexV2PreviewClient.self) private var client
    @Environment(\.dismiss) private var dismiss

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

            TextField("Relay HTTP URL", text: relayHTTPURLBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.mono(.caption))

            TextField("Relay WS URL", text: relayWSURLBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.mono(.caption))

            TextField("Daemon Health URL", text: daemonHealthURLBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.mono(.caption))

            TextField("Mac Device ID Override", text: macDeviceIDBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.mono(.caption))

            TextField("Prompt", text: promptBinding, axis: .vertical)
                .lineLimit(2...5)

            if client.isConnected {
                SettingsButton(client.isRunning ? "Stop Active Run" : "Send Prompt", isLoading: false) {
                    Task { @MainActor in
                        if client.isRunning {
                            await client.interruptCurrentRun()
                        } else {
                            await client.sendPrompt()
                        }
                    }
                }

                SettingsButton("Refresh Threads") {
                    Task { @MainActor in
                        await client.refreshThreads()
                    }
                }

                SettingsButton("Disconnect") {
                    client.disconnect()
                }
            } else {
                SettingsButton(client.isConnecting ? "Connecting..." : "Connect", isLoading: client.isConnecting) {
                    Task { @MainActor in
                        await client.connect()
                    }
                }

                SettingsButton("Connect and Send", isLoading: client.isConnecting) {
                    Task { @MainActor in
                        await client.connect(resetTimeline: client.timeline.frames.isEmpty)
                        await client.sendPrompt()
                    }
                }
            }

            SettingsButton("Reset Timeline") {
                client.clear()
            }

            SettingsButton("Reconnect") {
                Task { @MainActor in
                    client.disconnect()
                    await client.connect(resetTimeline: false)
                }
            }
        }
    }

    private var statusCard: some View {
        SettingsCard(title: "Status") {
            settingsRow("Connection", connectionLabel)
            settingsRow("Run Active", yesNo(client.isRunning))

            if let activeThreadID = client.activeThreadID, !activeThreadID.isEmpty {
                settingsRow("Active Thread", activeThreadID)
            }

            if let activeTurnID = client.activeTurnID, !activeTurnID.isEmpty {
                settingsRow("Active Turn", activeTurnID)
            }

            if let latestThreadID = client.timeline.latestThreadID, !latestThreadID.isEmpty {
                settingsRow("Latest Thread", latestThreadID)
            }

            if let latestTurnID = client.latestTurnID, !latestTurnID.isEmpty {
                settingsRow("Latest Turn", latestTurnID)
            }

            if let daemonHealth = client.daemonHealth {
                Divider()
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

    private var connectionLabel: String {
        if client.isConnecting {
            return "Connecting"
        }
        return client.isConnected ? "Connected" : "Disconnected"
    }

    private var savedPairRelayURL: String? {
        codex.preferredWakeRelayURL ?? codex.normalizedRelayURL
    }

    private var savedPairDeviceID: String? {
        codex.trustedPairPresentation?.deviceId
            ?? codex.normalizedRelayMacDeviceId
            ?? codex.normalizedLastTrustedMacDeviceId
    }

    private var relayHTTPURLBinding: Binding<String> {
        Binding(
            get: { client.relayHTTPBaseURLString },
            set: { client.relayHTTPBaseURLString = $0 }
        )
    }

    private var relayWSURLBinding: Binding<String> {
        Binding(
            get: { client.relayWSBaseURLString },
            set: { client.relayWSBaseURLString = $0 }
        )
    }

    private var daemonHealthURLBinding: Binding<String> {
        Binding(
            get: { client.daemonHealthURLString },
            set: { client.daemonHealthURLString = $0 }
        )
    }

    private var macDeviceIDBinding: Binding<String> {
        Binding(
            get: { client.macDeviceIDOverride },
            set: { client.macDeviceIDOverride = $0 }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { client.prompt },
            set: { client.prompt = $0 }
        )
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
        case let .threadListSnapshot(globalSequence, threads):
            let threadPreview = threads.prefix(3).map { thread in
                thread.title.isEmpty ? thread.threadID : thread.title
            }.joined(separator: ", ")
            let suffix = threadPreview.isEmpty ? "" : "\nthreads=\(threadPreview)"
            return "globalSequence=\(globalSequence)\nthreadCount=\(threads.count)\(suffix)"
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
