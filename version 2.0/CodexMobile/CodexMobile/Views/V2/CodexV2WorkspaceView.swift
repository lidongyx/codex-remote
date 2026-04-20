// FILE: CodexV2WorkspaceView.swift
// Purpose: Chat-first workspace for the Version 2.0 transport preview.
// Layer: View
// Exports: CodexV2WorkspaceView

import SwiftUI

private struct CodexV2WorkspaceBanner {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let actionTitle: String?
}

struct CodexV2WorkspaceView: View {
    @Environment(CodexService.self) private var codex
    @Environment(CodexV2PreviewClient.self) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var didApplySuggestedConnection = false
    @State private var isShowingThreadPicker = false
    @State private var isShowingConnectionSheet = false
    @FocusState private var isPromptFocused: Bool

    private let bottomAnchorID = "codex-v2-transcript-bottom"

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                threadHeaderCard
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                if let banner = activeBanner {
                    CodexV2WorkspaceBannerCard(
                        banner: banner,
                        action: bannerAction(for: banner)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                transcriptView
            }
        }
        .font(AppFont.body())
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Chats") {
                        isShowingThreadPicker = true
                    }

                    Button("New Chat") {
                        client.newConversation()
                        isPromptFocused = true
                    }

                    Button("Refresh Chats") {
                        Task { @MainActor in
                            await client.refreshThreads()
                        }
                    }

                    if client.isConnected {
                        Button("Reconnect") {
                            Task { @MainActor in
                                client.disconnect()
                                await client.connect(resetTimeline: false)
                            }
                        }

                        Button("Disconnect", role: .destructive) {
                            client.disconnect()
                        }
                    } else {
                        Button(client.isConnecting ? "Connecting..." : "Connect") {
                            Task { @MainActor in
                                await client.connect(resetTimeline: false)
                            }
                        }
                        .disabled(client.isConnecting)
                    }

                    Divider()

                    Button("Connection Details") {
                        isShowingConnectionSheet = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(AppFont.title3(weight: .regular))
                        .foregroundStyle(.primary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            composerBar
                .background(.ultraThinMaterial)
        }
        .task {
            applySuggestedConnectionIfNeeded()
            client.setForegroundActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            client.setForegroundActive(phase == .active)
        }
        .sheet(isPresented: $isShowingThreadPicker) {
            CodexV2ThreadPickerSheet(
                selectedThreadID: client.selectedThreadID,
                isStartingFreshConversation: client.isStartingFreshConversation,
                threads: client.timeline.threadSummaries
            )
        }
        .sheet(isPresented: $isShowingConnectionSheet) {
            CodexV2ConnectionSheet()
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.secondarySystemBackground),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.blue.opacity(0.08))
                .frame(width: 220, height: 220)
                .blur(radius: 26)
                .offset(x: -140, y: -280)

            Circle()
                .fill(Color.orange.opacity(0.08))
                .frame(width: 200, height: 200)
                .blur(radius: 30)
                .offset(x: 150, y: -180)
        }
    }

    private var threadHeaderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayedThreadTitle)
                        .font(AppFont.title3(weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(displayedThreadSubtitle)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer(minLength: 12)

                Button {
                    isShowingThreadPicker = true
                } label: {
                    Label("Chats", systemImage: "rectangle.stack")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                statusChip(
                    title: connectionStatusLabel,
                    tint: connectionStatusTint
                )

                if client.isRunning {
                    statusChip(title: "Running", tint: .orange)
                }

                if client.isStartingFreshConversation {
                    statusChip(title: "New Chat", tint: .blue)
                } else if client.selectedThreadSummary != nil {
                    statusChip(title: "Saved Chat", tint: .secondary)
                }

                if let runtimeMode = client.daemonHealth?.runtimeMode,
                   !runtimeMode.isEmpty {
                    statusChip(title: runtimeMode, tint: .blue)
                }
            }

            if let workspaceRoot = client.daemonHealth?.workspaceRoot,
               !workspaceRoot.isEmpty {
                Text(workspaceRoot)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if client.currentConversationItems.isEmpty {
                        emptyConversationState
                            .frame(maxWidth: .infinity, minHeight: 360)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 24)
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(client.currentConversationItems) { item in
                                CodexV2ConversationRow(item: item)
                                    .id(item.id)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollTranscriptToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: transcriptScrollFingerprint) { _, _ in
                scrollTranscriptToBottom(proxy: proxy, animated: true)
            }
        }
    }

    private var emptyConversationState: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyStateSystemImage)
                .font(AppFont.system(size: 28, weight: .semibold))
                .foregroundStyle(emptyStateTint)
                .frame(width: 64, height: 64)
                .background(
                    Circle()
                        .fill(emptyStateTint.opacity(0.14))
                )

            VStack(spacing: 8) {
                Text(emptyStateTitle)
                    .font(AppFont.title3(weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(emptyStateDetail)
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let summaryPreview = selectedThreadPreview,
               !summaryPreview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chat Preview")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(summaryPreview)
                        .font(AppFont.body())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }

            if !client.isConnected && !client.isConnecting {
                Button {
                    Task { @MainActor in
                        await client.connect(resetTimeline: false)
                    }
                } label: {
                    Text("Connect")
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.primary)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    private var composerBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(composerContextLabel)
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if client.selectedThreadID != nil || client.isStartingFreshConversation {
                    Button("New Chat") {
                        client.newConversation()
                        isPromptFocused = true
                    }
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.primary)
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message Codex…", text: promptBinding, axis: .vertical)
                    .focused($isPromptFocused)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                Button {
                    Task { @MainActor in
                        if client.isRunning {
                            await client.interruptCurrentRun()
                        } else {
                            await client.sendPrompt()
                            isPromptFocused = false
                        }
                    }
                } label: {
                    Image(systemName: client.isRunning ? "stop.fill" : "arrow.up")
                        .font(AppFont.system(size: 16, weight: .semibold))
                        .foregroundStyle(primaryComposerButtonForeground)
                        .frame(width: 48, height: 48)
                        .background(
                            Circle()
                                .fill(primaryComposerButtonBackground)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isPrimaryComposerActionEnabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var activeBanner: CodexV2WorkspaceBanner? {
        if client.isReconnecting {
            return CodexV2WorkspaceBanner(
                title: "Reconnecting",
                detail: client.isRestoringSelectedThread
                    ? "Restoring the chat you were viewing before the connection dropped. Attempt \(client.reconnectAttemptCount)."
                    : "Re-establishing the V2 chat session. Attempt \(client.reconnectAttemptCount).",
                systemImage: "bolt.horizontal.circle.fill",
                tint: .orange,
                actionTitle: nil
            )
        }

        if client.isConnecting {
            return CodexV2WorkspaceBanner(
                title: "Connecting",
                detail: "Opening the V2 chat session and loading your recent chats.",
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                tint: .orange,
                actionTitle: nil
            )
        }

        if !client.isConnected {
            return CodexV2WorkspaceBanner(
                title: "Chat is offline",
                detail: client.lastErrorMessage
                    ?? "Connect the V2 chat runtime when you want to use the beta conversation flow.",
                systemImage: "bolt.slash.circle.fill",
                tint: .secondary,
                actionTitle: "Connect"
            )
        }

        if client.isRestoringSelectedThread {
            let detail: String
            if let snapshot = client.displayedThreadRecoverySnapshot {
                detail = snapshot.hasMore
                    ? "Recovered \(snapshot.eventCount) events so far. More catch-up is still available."
                    : "Recovered \(snapshot.eventCount) events and refreshed the latest chat state."
            } else {
                detail = "Refreshing the selected chat so the timeline stays coherent after reconnect."
            }

            return CodexV2WorkspaceBanner(
                title: "Restoring chat",
                detail: detail,
                systemImage: "arrow.clockwise.circle.fill",
                tint: .blue,
                actionTitle: "Chats"
            )
        }

        return nil
    }

    private func bannerAction(for banner: CodexV2WorkspaceBanner) -> (() -> Void)? {
        switch banner.actionTitle {
        case "Connect":
            return {
                Task { @MainActor in
                    await client.connect(resetTimeline: false)
                }
            }
        case "Chats":
            return {
                isShowingThreadPicker = true
            }
        default:
            return nil
        }
    }

    private var connectionStatusLabel: String {
        if client.isReconnecting {
            return "Reconnecting"
        }
        if client.isConnecting {
            return "Connecting"
        }
        return client.isConnected ? "Connected" : "Offline"
    }

    private var connectionStatusTint: Color {
        if client.isReconnecting || client.isConnecting {
            return .orange
        }
        return client.isConnected ? .green : .secondary
    }

    private var displayedThreadTitle: String {
        if client.isStartingFreshConversation {
            return "New Chat"
        }

        if let summary = client.selectedThreadSummary {
            let trimmedTitle = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTitle.isEmpty ? "Untitled Chat" : trimmedTitle
        }

        if client.displayedConversationThreadID == CodexV2ConversationReducer.pendingThreadKey {
            return "Draft Chat"
        }

        if client.isConnected {
            return "Choose a Chat"
        }

        return "V2 Chat Beta"
    }

    private var displayedThreadSubtitle: String {
        if client.isStartingFreshConversation {
            return "Your next message will start a fresh chat instead of replying inside an existing one."
        }

        if let preview = selectedThreadPreview, !preview.isEmpty {
            return preview
        }

        if let workspaceRoot = client.daemonHealth?.workspaceRoot,
           !workspaceRoot.isEmpty {
            return workspaceRoot
        }

        if client.isConnected {
            return "Continue an existing chat or start a fresh one in the isolated V2 beta workspace."
        }

        return "This beta chat flow stays separate from the legacy bridge until reconnect and recovery are solid."
    }

    private var selectedThreadPreview: String? {
        client.selectedThreadSummary?.preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyStateSystemImage: String {
        if client.isRestoringSelectedThread {
            return "arrow.clockwise.circle.fill"
        }
        if client.isConnecting || client.isReconnecting {
            return "bolt.horizontal.circle.fill"
        }
        if client.isStartingFreshConversation {
            return "square.and.pencil.circle.fill"
        }
        if client.selectedThreadID != nil {
            return "rectangle.stack.badge.person.crop"
        }
        return "message.circle.fill"
    }

    private var emptyStateTint: Color {
        if client.isRestoringSelectedThread {
            return .blue
        }
        if client.isConnecting || client.isReconnecting {
            return .orange
        }
        if client.isStartingFreshConversation {
            return .blue
        }
        return .secondary
    }

    private var emptyStateTitle: String {
        if client.isRestoringSelectedThread {
            return "Restoring chat"
        }
        if client.isConnecting || client.isReconnecting {
            return "Preparing chat"
        }
        if client.isStartingFreshConversation {
            return "Ready for a new chat"
        }
        if client.selectedThreadID != nil {
            return "No replayed messages yet"
        }
        return "No chat selected"
    }

    private var emptyStateDetail: String {
        if client.isRestoringSelectedThread {
            if let snapshot = client.displayedThreadRecoverySnapshot {
                return snapshot.hasMore
                    ? "The relay has already delivered \(snapshot.eventCount) recovery events. More thread history is still being pulled in."
                    : "The latest messages are restored. You can keep chatting in this thread."
            }
            return "Refreshing the selected chat so reconnect keeps the page stable."
        }

        if client.isConnecting || client.isReconnecting {
            return "As soon as the session is ready, this page will switch back into the active chat automatically."
        }

        if client.isStartingFreshConversation {
            return "Type below to begin a fresh chat without mixing it into an older thread."
        }

        if client.selectedThreadID != nil {
            return "This chat does not have restored messages yet. Send a message to continue from here."
        }

        return "Open a chat from the picker or send a message to create a new one."
    }

    private var composerContextLabel: String {
        if client.isRunning {
            return "A run is active. Stop it before sending a new message."
        }
        if client.isStartingFreshConversation {
            return "Sending will start a new chat."
        }
        if let summary = client.selectedThreadSummary {
            let trimmedTitle = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTitle.isEmpty
                ? "Replying inside the selected chat."
                : "Replying in \(trimmedTitle)."
        }
        return "Select a chat or start a new one."
    }

    private var primaryComposerButtonBackground: Color {
        if client.isRunning {
            return Color.orange
        }
        return isPrimaryComposerActionEnabled ? Color.primary : Color(.tertiarySystemFill)
    }

    private var primaryComposerButtonForeground: Color {
        isPrimaryComposerActionEnabled ? Color(.systemBackground) : .secondary
    }

    private var isPrimaryComposerActionEnabled: Bool {
        if client.isRunning {
            return client.isConnected
        }

        return !promptBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !client.isConnecting
    }

    private var transcriptScrollFingerprint: String {
        let lastItemID = client.currentConversationItems.last?.id ?? "empty"
        let lastLength = client.currentConversationItems.last?.text.count ?? 0
        let reconnectFlag = client.isReconnecting ? "reconnecting" : "steady"
        let restoreFlag = client.isRestoringSelectedThread ? "restoring" : "stable"
        return "\(lastItemID)-\(lastLength)-\(reconnectFlag)-\(restoreFlag)"
    }

    private func scrollTranscriptToBottom(
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard !client.currentConversationItems.isEmpty else {
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
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

    private var promptBinding: Binding<String> {
        Binding(
            get: { client.prompt },
            set: { client.prompt = $0 }
        )
    }
}

private struct CodexV2WorkspaceBannerCard: View {
    let banner: CodexV2WorkspaceBanner
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: banner.systemImage)
                .font(AppFont.system(size: 16, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(banner.tint.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                Text(banner.detail)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let action,
               let actionTitle = banner.actionTitle {
                Button(actionTitle, action: action)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.primary)
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct CodexV2ConversationRow: View {
    let item: CodexV2ConversationItem
    @State private var isReasoningExpanded = false

    var body: some View {
        switch item.role {
        case .reasoning:
            reasoningCard
        case .user, .assistant, .error:
            bubbleRow
        }
    }

    private var bubbleRow: some View {
        VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 6) {
            Text(roleLabel)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(displayText)
                    .font(AppFont.body())
                    .foregroundStyle(bubbleForeground)
                    .textSelection(.enabled)

                if item.isStreaming {
                    Text("Streaming…")
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(bubbleForeground.opacity(0.75))
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(bubbleBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(bubbleStroke, lineWidth: bubbleStrokeLineWidth)
            )
            .frame(maxWidth: 320, alignment: item.role == .user ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
    }

    private var reasoningCard: some View {
        DisclosureGroup(isExpanded: $isReasoningExpanded) {
            Text(displayText)
                .font(AppFont.body())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .textSelection(.enabled)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(AppFont.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(item.isStreaming ? "Thinking…" : "Thinking")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var displayText: String {
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? " " : trimmed
    }

    private var roleLabel: String {
        switch item.role {
        case .user:
            return "You"
        case .assistant:
            return "Codex"
        case .error:
            return "Error"
        case .reasoning:
            return "Thinking"
        }
    }

    private var bubbleBackground: Color {
        switch item.role {
        case .user:
            return Color.primary
        case .assistant:
            return Color(.systemBackground)
        case .error:
            return Color.red.opacity(0.12)
        case .reasoning:
            return Color(.secondarySystemBackground)
        }
    }

    private var bubbleForeground: Color {
        switch item.role {
        case .user:
            return Color(.systemBackground)
        case .assistant:
            return .primary
        case .error:
            return .red
        case .reasoning:
            return .primary
        }
    }

    private var bubbleStroke: Color {
        switch item.role {
        case .assistant:
            return Color.primary.opacity(0.08)
        case .error:
            return Color.red.opacity(0.18)
        case .user, .reasoning:
            return .clear
        }
    }

    private var bubbleStrokeLineWidth: CGFloat {
        item.role == .assistant || item.role == .error ? 1 : 0
    }
}

private struct CodexV2ThreadPickerSheet: View {
    let selectedThreadID: String?
    let isStartingFreshConversation: Bool
    let threads: [CodexV2ThreadSummary]

    @Environment(CodexV2PreviewClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        client.newConversation()
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.pencil")
                                .font(AppFont.body(weight: .semibold))
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Start New Chat")
                                    .font(AppFont.body(weight: .semibold))
                                    .foregroundStyle(.primary)

                                Text("Send the next message into a fresh chat.")
                                    .font(AppFont.caption())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if isStartingFreshConversation {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Chats") {
                    if threads.isEmpty {
                        Text("No chats loaded yet. Connect and refresh to pull the latest chat list.")
                            .font(AppFont.body())
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(threads, id: \.threadID) { thread in
                            Button {
                                Task { @MainActor in
                                    await client.selectThread(thread.threadID)
                                    dismiss()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(thread.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                             ? "Untitled Chat"
                                             : thread.title)
                                            .font(AppFont.body(weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Spacer()

                                        if thread.isRunning {
                                            Text("Running")
                                                .font(AppFont.caption(weight: .semibold))
                                                .foregroundStyle(.orange)
                                        }

                                        if selectedThreadID == thread.threadID {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }

                                    if !thread.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(thread.preview)
                                            .font(AppFont.caption())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        Task { @MainActor in
                            await client.refreshThreads()
                        }
                    }
                    .disabled(client.isConnecting)
                }
            }
        }
    }
}

private struct CodexV2ConnectionSheet: View {
    @Environment(CodexService.self) private var codex
    @Environment(CodexV2PreviewClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    SettingsCard(title: "Connection") {
                        if let trustedPairPresentation = codex.trustedPairPresentation {
                            TrustedPairSummaryView(presentation: trustedPairPresentation)
                        }

                        HStack(spacing: 8) {
                            CodexV2SheetPill(label: client.isConnected ? "Connected" : (client.isConnecting ? "Connecting" : "Disconnected"))
                            CodexV2SheetPill(label: "Beta")
                            if client.isReconnecting {
                                CodexV2SheetPill(label: "Retry \(client.reconnectAttemptCount)")
                            }
                        }

                        if let workspaceRoot = client.daemonHealth?.workspaceRoot,
                           !workspaceRoot.isEmpty {
                            Text(workspaceRoot)
                                .font(AppFont.mono(.caption))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        HStack(spacing: 10) {
                            if client.isConnected {
                                SettingsButton("Refresh Chats") {
                                    Task { @MainActor in
                                        await client.refreshThreads()
                                    }
                                }

                                SettingsButton("Reconnect") {
                                    Task { @MainActor in
                                        client.disconnect()
                                        await client.connect(resetTimeline: false)
                                    }
                                }
                            } else {
                                SettingsButton(client.isConnecting ? "Connecting..." : "Connect", isLoading: client.isConnecting) {
                                    Task { @MainActor in
                                        await client.connect(resetTimeline: false)
                                    }
                                }
                            }
                        }

                        if client.isConnected {
                            SettingsButton("Disconnect", role: .destructive) {
                                client.disconnect()
                            }
                        }
                    }

                    SettingsCard(title: "Runtime") {
                        statusRow("Session Ready", yesNo(client.timeline.didReceiveSessionReady))
                        statusRow("Chat List", yesNo(client.timeline.didReceiveThreadList))
                        statusRow("Run Completion", yesNo(client.timeline.didReceiveRunCompletion))
                        statusRow("Catch-up", yesNo(client.timeline.didReceiveCatchUpBatch))

                        if let activeThreadID = client.activeThreadID, !activeThreadID.isEmpty {
                            statusRow("Active Chat", activeThreadID)
                        }

                        if let activeTurnID = client.activeTurnID, !activeTurnID.isEmpty {
                            statusRow("Active Turn", activeTurnID)
                        }

                        if let latestTurnID = client.latestTurnID, !latestTurnID.isEmpty {
                            statusRow("Latest Turn", latestTurnID)
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
                .padding()
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
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
}

private struct CodexV2SheetPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemFill))
            )
    }
}
