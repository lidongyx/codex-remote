// FILE: CodexV2WorkspaceView.swift
// Purpose: Main app-facing workspace for the Version 2.0 transport preview.
// Layer: View
// Exports: CodexV2WorkspaceView

import SwiftUI

private struct CodexV2WorkspaceEntry: Identifiable {
    enum Role {
        case assistant
        case reasoning
        case system
        case error
    }

    let id: String
    let role: Role
    let title: String
    let body: String
}

struct CodexV2WorkspaceView: View {
    @Environment(CodexService.self) private var codex
    @State private var client = CodexV2PreviewClient()
    @State private var didApplySuggestedConnection = false
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                statusCard
                threadsCard
                transcriptCard
            }
            .padding()
        }
        .font(AppFont.body())
        .navigationTitle("Version 2.0")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            composerBar
                .background(.ultraThinMaterial)
        }
        .task {
            applySuggestedConnectionIfNeeded()
        }
    }

    private var heroCard: some View {
        SettingsCard(title: "V2 Workspace") {
            Text("This is the app-facing entry for the new relay-backed `codexd` path. It runs beside the current bridge flow so we can validate the new stack without cutting over the whole product yet.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if let trustedPairPresentation = codex.trustedPairPresentation {
                TrustedPairSummaryView(presentation: trustedPairPresentation)
            }

            HStack(spacing: 10) {
                statusChip(
                    title: client.isConnecting ? "Connecting" : (client.isConnected ? "Connected" : "Disconnected"),
                    tint: client.isConnecting ? .orange : (client.isConnected ? .green : .secondary)
                )

                if client.isRunning {
                    statusChip(title: "Run Active", tint: .orange)
                }

                if let runtimeMode = client.daemonHealth?.runtimeMode, !runtimeMode.isEmpty {
                    statusChip(title: runtimeMode, tint: .blue)
                }
            }

            if let workspaceRoot = client.daemonHealth?.workspaceRoot, !workspaceRoot.isEmpty {
                Text(workspaceRoot)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if client.isConnected {
                HStack(spacing: 10) {
                    SettingsButton(client.isRunning ? "Stop Run" : "Send Prompt") {
                        Task { @MainActor in
                            if client.isRunning {
                                await client.interruptCurrentRun()
                            } else {
                                await client.sendPrompt()
                            }
                        }
                    }

                    SettingsButton("Refresh") {
                        Task { @MainActor in
                            await client.refreshThreads()
                        }
                    }
                }

                SettingsButton("Disconnect", role: .destructive) {
                    client.disconnect()
                }
            } else {
                SettingsButton(client.isConnecting ? "Connecting..." : "Connect", isLoading: client.isConnecting) {
                    Task { @MainActor in
                        await client.connect()
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        SettingsCard(title: "Run Status") {
            settingsRow("Session Ready", yesNo(client.timeline.didReceiveSessionReady))
            settingsRow("Thread List", yesNo(client.timeline.didReceiveThreadList))
            settingsRow("Run Completion", yesNo(client.timeline.didReceiveRunCompletion))
            settingsRow("Catch-up", yesNo(client.timeline.didReceiveCatchUpBatch))

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

            if let error = client.lastErrorMessage, !error.isEmpty {
                Divider()
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var transcriptCard: some View {
        SettingsCard(title: "Conversation") {
            if transcriptEntries.isEmpty {
                Text("Connect to `codexd`, then send a prompt here. This surface is the bridge between the V2 transport and a real in-app chat workflow.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(transcriptEntries) { entry in
                    VStack(alignment: entry.role == .assistant ? .trailing : .leading, spacing: 6) {
                        Text(entry.title)
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(entry.body)
                            .font(AppFont.body())
                            .foregroundStyle(entryForegroundColor(for: entry.role))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: entryAlignment(for: entry.role))
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(entryBackgroundColor(for: entry.role))
                            )
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: entryAlignment(for: entry.role))

                    if entry.id != transcriptEntries.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var threadsCard: some View {
        SettingsCard(title: "Threads") {
            if client.timeline.threadSummaries.isEmpty {
                Text("No V2 threads loaded yet. Tap Refresh after connecting.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(client.timeline.threadSummaries, id: \.threadID) { thread in
                    Button {
                        Task { @MainActor in
                            await client.selectThread(thread.threadID)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(thread.title.isEmpty ? "Untitled Thread" : thread.title)
                                    .font(AppFont.subheadline(weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if thread.isRunning {
                                    statusChip(title: "Running", tint: .orange)
                                }
                            }

                            if !thread.preview.isEmpty {
                                Text(thread.preview)
                                    .font(AppFont.caption())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selectedThreadMatches(thread) ? Color(.secondarySystemFill) : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)

                    if thread.threadID != client.timeline.threadSummaries.last?.threadID {
                        Divider()
                    }
                }
            }
        }
    }

    private var composerBar: some View {
        VStack(spacing: 12) {
            TextField("Ask `codexd` to do something…", text: $client.prompt, axis: .vertical)
                .focused($isPromptFocused)
                .lineLimit(2...5)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )

            HStack(spacing: 10) {
                if !client.isConnected {
                    SettingsButton(client.isConnecting ? "Connecting..." : "Connect and Send", isLoading: client.isConnecting) {
                        Task { @MainActor in
                            await client.connect(resetTimeline: transcriptEntries.isEmpty)
                            await client.sendPrompt()
                        }
                    }
                } else {
                    SettingsButton(client.isRunning ? "Stop Active Run" : "Send Prompt") {
                        Task { @MainActor in
                            if client.isRunning {
                                await client.interruptCurrentRun()
                            } else {
                                await client.sendPrompt()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var transcriptEntries: [CodexV2WorkspaceEntry] {
        client.timeline.frames.enumerated().compactMap { index, frame in
            switch frame {
            case let .assistantText(_, _, _, delta):
                guard frameBelongsToSelectedThread(frame) else { return nil }
                let body = delta.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return CodexV2WorkspaceEntry(
                    id: "assistant-\(index)",
                    role: .assistant,
                    title: "Assistant",
                    body: body
                )
            case let .reasoning(_, _, _, _, delta):
                guard frameBelongsToSelectedThread(frame) else { return nil }
                let body = delta.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return CodexV2WorkspaceEntry(
                    id: "reasoning-\(index)",
                    role: .reasoning,
                    title: "Reasoning",
                    body: body
                )
            case let .runStarted(_, _, _, model):
                guard frameBelongsToSelectedThread(frame) else { return nil }
                return CodexV2WorkspaceEntry(
                    id: "started-\(index)",
                    role: .system,
                    title: "Run Started",
                    body: "Model: \(model)"
                )
            case let .runCompletion(_, _, _, result, errorMessage):
                guard frameBelongsToSelectedThread(frame) else { return nil }
                let body = errorMessage.isEmpty ? "Result: \(result)" : "Result: \(result)\n\(errorMessage)"
                return CodexV2WorkspaceEntry(
                    id: "completion-\(index)",
                    role: errorMessage.isEmpty ? .system : .error,
                    title: "Run Completion",
                    body: body
                )
            case let .error(code, message, retryable):
                return CodexV2WorkspaceEntry(
                    id: "error-\(index)",
                    role: .error,
                    title: "Transport Error",
                    body: "\(code) · retryable=\(retryable)\n\(message)"
                )
            case let .sessionReady(sessionID, connectionMode, _):
                return CodexV2WorkspaceEntry(
                    id: "session-\(index)",
                    role: .system,
                    title: "Session Ready",
                    body: "\(connectionMode) · \(sessionID)"
                )
            case let .threadListSnapshot(_, threads):
                return CodexV2WorkspaceEntry(
                    id: "thread-list-\(index)",
                    role: .system,
                    title: "Thread List",
                    body: "\(threads.count) threads visible"
                )
            case let .threadCatchUpBatch(threadID, latestThreadSequence, eventCount, hasMore):
                guard frameBelongsToSelectedThread(frame) else { return nil }
                return CodexV2WorkspaceEntry(
                    id: "catchup-\(index)",
                    role: .system,
                    title: "Catch-up",
                    body: "thread=\(threadID)\nlatest=\(latestThreadSequence)\nevents=\(eventCount)\nhasMore=\(hasMore)"
                )
            }
        }
    }

    private func applySuggestedConnectionIfNeeded() {
        guard !didApplySuggestedConnection else { return }
        didApplySuggestedConnection = true
        client.applySuggestedConnection(
            relayURLString: codex.preferredWakeRelayURL ?? codex.normalizedRelayURL,
            macDeviceID: codex.trustedPairPresentation?.deviceId
                ?? codex.normalizedRelayMacDeviceId
                ?? codex.normalizedLastTrustedMacDeviceId
        )
    }

    private func statusChip(title: String, tint: Color) -> some View {
        Text(title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
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

    private func selectedThreadMatches(_ thread: CodexV2ThreadSummary) -> Bool {
        let selectedThreadID = client.selectedThreadID ?? client.timeline.latestThreadID
        return selectedThreadID == thread.threadID
    }

    private func frameBelongsToSelectedThread(_ frame: CodexV2ServerFrame) -> Bool {
        guard let selectedThreadID = client.selectedThreadID ?? client.timeline.latestThreadID else {
            return true
        }

        switch frame {
        case let .runStarted(threadID, _, _, _),
             let .reasoning(threadID, _, _, _, _),
             let .assistantText(threadID, _, _, _),
             let .runCompletion(threadID, _, _, _, _),
             let .threadCatchUpBatch(threadID, _, _, _):
            return threadID == selectedThreadID
        case .sessionReady, .threadListSnapshot, .error:
            return true
        }
    }

    private func entryAlignment(for role: CodexV2WorkspaceEntry.Role) -> Alignment {
        role == .assistant ? .trailing : .leading
    }

    private func entryBackgroundColor(for role: CodexV2WorkspaceEntry.Role) -> Color {
        switch role {
        case .assistant:
            return Color(.systemBlue).opacity(0.14)
        case .reasoning:
            return Color(.secondarySystemFill)
        case .system:
            return Color(.tertiarySystemFill)
        case .error:
            return Color.red.opacity(0.12)
        }
    }

    private func entryForegroundColor(for role: CodexV2WorkspaceEntry.Role) -> Color {
        switch role {
        case .assistant, .reasoning, .system:
            return .primary
        case .error:
            return .red
        }
    }
}
