// FILE: SidebarView.swift
// Purpose: Orchestrates the sidebar experience with modular presentation components.
// Layer: View
// Exports: SidebarView
// Depends on: CodexService, Sidebar* components/helpers

import SwiftUI

struct SidebarView: View {
    @Environment(CodexService.self) private var codex
    @Environment(CodexV2PreviewClient.self) private var codexV2
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selectedThread: CodexThread?
    @Binding var showSettings: Bool
    @Binding var isSearchActive: Bool
    var showsV2WorkspaceButton: Bool = false
    var isV2WorkspaceSelected: Bool = false
    var showsInlineCloseButton: Bool = false
    var isVisible: Bool = true

    let onClose: () -> Void
    let onOpenThread: (CodexThread) -> Void
    let onOpenV2Workspace: () -> Void

    @State private var searchText = ""
    @State private var isCreatingThread = false
    @State private var groupedThreads: [SidebarThreadGroup] = []
    @State private var isShowingNewChatProjectPicker = false
    @State private var projectGroupPendingArchive: SidebarThreadGroup? = nil
    @State private var threadPendingDeletion: CodexThread? = nil
    @State private var createThreadErrorMessage: String? = nil
    @State private var cachedDiffTotals: [String: TurnSessionDiffTotals] = [:]
    @State private var cachedDiffRevisionByThreadID: [String: Int] = [:]
    @State private var cachedRunBadges: [String: CodexThreadRunBadgeState] = [:]
    @State private var lastGroupedThreadsFingerprint: Int = 0
    @State private var lastDiffFingerprint: Int = 0
    @State private var lastBadgeFingerprint: Int = 0
    @State private var sidebarDebugSequence = 0

    var body: some View {
        let diffTotalsByThreadID = cachedDiffTotals

        VStack(alignment: .leading, spacing: 0) {
            SidebarHeaderView(
                showsCloseButton: showsInlineCloseButton,
                onClose: onClose
            )

            SidebarSearchField(text: $searchText, isActive: $isSearchActive)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

            SidebarNewChatButton(
                isCreatingThread: isCreatingThread,
                isEnabled: canCreateThread,
                statusMessage: nil,
                action: handleNewChatButtonTap
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if showsV2WorkspaceButton {
                SidebarV2WorkspaceButton(
                    isSelected: isV2WorkspaceSelected,
                    action: handleOpenV2WorkspaceTap
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                if filteredV2Threads.isEmpty {
                    SidebarV2WorkspaceSummary(
                        isConnected: codexV2.isConnected,
                        threadCount: codexV2.timeline.threadSummaries.count
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                } else {
                    SidebarV2ThreadSection(
                        threads: filteredV2Threads,
                        selectedThreadID: codexV2.selectedThreadID,
                        onSelectThread: handleOpenV2Thread
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }

            SidebarThreadListView(
                isFiltering: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isConnected: codex.isConnected,
                isCreatingThread: isCreatingThread,
                threads: codex.threads,
                groups: groupedThreads,
                selectedThread: selectedThread,
                bottomContentInset: 0,
                timingLabelProvider: { SidebarRelativeTimeFormatter.compactLabel(for: $0) },
                diffTotalsByThreadID: diffTotalsByThreadID,
                runBadgeStateByThreadID: cachedRunBadges,
                onSelectThread: selectThread,
                onCreateThreadInProjectGroup: { group in
                    handleNewChatTap(preferredProjectPath: group.projectPath)
                },
                onArchiveProjectGroup: { group in
                    projectGroupPendingArchive = group
                },
                onRenameThread: { thread, newName in
                    codex.renameThread(thread.id, name: newName)
                },
                onArchiveToggleThread: { thread in
                    if thread.syncState == .archivedLocal {
                        codex.unarchiveThread(thread.id)
                    } else {
                        codex.archiveThread(thread.id)
                        if selectedThread?.id == thread.id {
                            selectedThread = nil
                        }
                    }
                },
                onDeleteThread: { thread in
                    threadPendingDeletion = thread
                }
            )
            .refreshable {
                await refreshThreads()
            }

            HStack(spacing: 10) {
                SidebarFloatingSettingsButton(colorScheme: colorScheme, action: openSettings)
                Spacer(minLength: 0)
                if let trustedPairPresentation = codex.trustedPairPresentation {
                    SidebarMacConnectionStatusView(
                        name: trustedPairPresentation.name,
                        systemName: trustedPairPresentation.systemName,
                        isConnected: codex.isConnected
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
            debugSidebarLog("task start visible=\(isVisible) threadCount=\(codex.threads.count)")
            rebuildGroupedThreads()
            rebuildCachedSidebarState()
            if codex.isConnected, codex.threads.isEmpty {
                await refreshThreads()
            }
        }
        .onChange(of: codex.threads) { _, _ in
            debugSidebarLog(
                "threads changed while \(isVisible ? "visible" : "hidden-prewarmed") "
                    + "threadCount=\(codex.threads.count)"
            )
            rebuildGroupedThreads()
            rebuildCachedSidebarState()
        }
        .onChange(of: searchText) { _, _ in
            debugSidebarLog("search changed queryLength=\(searchText.count)")
            rebuildGroupedThreads()
        }
        .onChange(of: codexV2.timeline.threadSummaries) { _, _ in
            debugSidebarLog(
                "v2 threads changed count=\(codexV2.timeline.threadSummaries.count) connected=\(codexV2.isConnected)"
            )
        }
        .onChange(of: diffFingerprint) { _, _ in
            debugSidebarLog("diff fingerprint changed visible=\(isVisible)")
            rebuildCachedDiffTotals()
        }
        .onChange(of: badgeFingerprint) { _, _ in
            debugSidebarLog("badge fingerprint changed visible=\(isVisible)")
            rebuildCachedRunBadges()
        }
        .onChange(of: isVisible) { _, visible in
            debugSidebarLog("visibility changed visible=\(visible)")
        }
        .overlay {
            if SidebarThreadsLoadingPresentation.shouldShowOverlay(
                isLoadingThreads: codex.isLoadingThreads,
                threadCount: codex.threads.count
            ) {
                ProgressView()
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $isShowingNewChatProjectPicker) {
            SidebarNewChatProjectPickerSheet(
                choices: newChatProjectChoices,
                onSelectProject: { projectPath in
                    handleNewChatTap(preferredProjectPath: projectPath)
                },
                onSelectWorktreeProject: { projectPath in
                    handleNewWorktreeChatTap(preferredProjectPath: projectPath)
                },
                onSelectWithoutProject: {
                    handleNewChatTap(preferredProjectPath: nil)
                }
            )
        }
        .confirmationDialog(
            "Archive \"\(projectGroupPendingArchive?.label ?? "project")\"?",
            isPresented: Binding(
                get: { projectGroupPendingArchive != nil },
                set: { if !$0 { projectGroupPendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive Project") {
                archivePendingProjectGroup()
            }
            Button("Cancel", role: .cancel) {
                projectGroupPendingArchive = nil
            }
        } message: {
            Text("All active chats in this project will be archived.")
        }
        .alert(
            "Delete \"\(threadPendingDeletion?.displayTitle ?? "conversation")\"?",
            isPresented: Binding(
                get: { threadPendingDeletion != nil },
                set: { if !$0 { threadPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let thread = threadPendingDeletion {
                    if selectedThread?.id == thread.id {
                        selectedThread = nil
                    }
                    codex.deleteThread(thread.id)
                }
                threadPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                threadPendingDeletion = nil
            }
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { createThreadErrorMessage != nil },
                set: { if !$0 { createThreadErrorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    createThreadErrorMessage = nil
                }
            },
            message: {
                Text(createThreadErrorMessage ?? "Please try again.")
            }
        )
    }

    // MARK: - Actions

    private func refreshThreads() async {
        guard codex.isConnected else { return }
        let startedAt = Date()
        debugSidebarLog("refreshThreads start threadCount=\(codex.threads.count)")
        do {
            try await codex.listThreads()
            debugSidebarLog(
                "refreshThreads success durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                    + "threadCount=\(codex.threads.count)"
            )
        } catch {
            debugSidebarLog(
                "refreshThreads failed durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                    + "error=\(error.localizedDescription)"
            )
            // Error stored in CodexService.
        }
    }

    // Shows a native sheet so folder names and full paths stay readable on small screens.
    private func handleNewChatButtonTap() {
        if newChatProjectChoices.isEmpty {
            handleNewChatTap(preferredProjectPath: nil)
            return
        }

        isShowingNewChatProjectPicker = true
    }

    private func handleNewChatTap(preferredProjectPath: String?) {
        Task { @MainActor in
            createThreadErrorMessage = nil
            isCreatingThread = true
            defer { isCreatingThread = false }

            do {
                let thread = try await WorktreeFlowCoordinator.startNewLocalChat(
                    preferredProjectPath: preferredProjectPath,
                    codex: codex
                )
                onOpenThread(thread)
            } catch {
                let message = error.localizedDescription
                codex.lastErrorMessage = message
                createThreadErrorMessage = message.isEmpty ? "Unable to create a chat right now." : message
            }
        }
    }

    private func handleNewWorktreeChatTap(preferredProjectPath: String) {
        Task { @MainActor in
            createThreadErrorMessage = nil
            isCreatingThread = true
            defer { isCreatingThread = false }

            do {
                let thread = try await WorktreeFlowCoordinator.startNewWorktreeChat(
                    preferredProjectPath: preferredProjectPath,
                    codex: codex
                )
                onOpenThread(thread)
            } catch {
                let message = error.localizedDescription
                codex.lastErrorMessage = message
                createThreadErrorMessage = message.isEmpty ? "Unable to create a worktree chat right now." : message
            }
        }
    }

    private func selectThread(_ thread: CodexThread) {
        debugSidebarLog("selectThread id=\(thread.id) title=\(thread.displayTitle)")
        searchText = ""
        onOpenThread(thread)
    }

    private func openSettings() {
        searchText = ""
        showSettings = true
        onClose()
    }

    private func handleOpenV2WorkspaceTap() {
        searchText = ""
        onOpenV2Workspace()
    }

    private func handleOpenV2Thread(_ thread: CodexV2ThreadSummary) {
        searchText = ""
        Task { @MainActor in
            await codexV2.selectThread(thread.threadID)
            onOpenV2Workspace()
        }
    }

    // Archives every live chat in the selected project group and clears the current selection if needed.
    private func archivePendingProjectGroup() {
        guard let group = projectGroupPendingArchive else { return }

        let threadIDs = SidebarThreadGrouping.liveThreadIDsForProjectGroup(group, in: codex.threads)
        let selectedThreadWasArchived = selectedThread.map { selected in
            threadIDs.contains(selected.id)
        } ?? false

        _ = codex.archiveThreadGroup(threadIDs: threadIDs)

        if selectedThreadWasArchived {
            selectedThread = codex.threads.first(where: { thread in
                thread.syncState == .live && !threadIDs.contains(thread.id)
            })
        }

        projectGroupPendingArchive = nil
    }

    // Rebuilds sidebar sections only when the source thread array changes.
    private func rebuildGroupedThreads() {
        let startedAt = Date()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: [CodexThread]
        if query.isEmpty {
            source = codex.threads
        } else {
            source = codex.threads.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.projectDisplayName.localizedCaseInsensitiveContains(query)
            }
        }
        let fingerprint = groupingFingerprint(query: query, source: source)
        guard fingerprint != lastGroupedThreadsFingerprint else { return }
        lastGroupedThreadsFingerprint = fingerprint
        groupedThreads = SidebarThreadGrouping.makeGroups(from: source)
        debugSidebarLog(
            "rebuildGroupedThreads durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "queryLength=\(query.count) sourceCount=\(source.count) groupCount=\(groupedThreads.count)"
        )
    }

    private func groupingFingerprint(query: String, source: [CodexThread]) -> Int {
        var hasher = Hasher()
        hasher.combine(query)
        for thread in source {
            hasher.combine(thread)
        }
        return hasher.finalize()
    }

    // Cheap fingerprint: hashes thread IDs + message revisions (O(n) integer work, no message access).
    private var diffFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(codex.hasAnyRunningTurn)
        for thread in codex.threads {
            hasher.combine(thread.id)
            hasher.combine(codex.messageRevision(for: thread.id))
        }
        return hasher.finalize()
    }

    // Cheap fingerprint for run badge state — changes when running/ready/failed sets change.
    private var badgeFingerprint: Int {
        var hasher = Hasher()
        for thread in codex.threads {
            hasher.combine(thread.id)
            if let badge = codex.threadRunBadgeState(for: thread.id) {
                hasher.combine(badge)
            }
        }
        return hasher.finalize()
    }

    private func rebuildCachedSidebarState() {
        let startedAt = Date()
        rebuildCachedDiffTotals()
        rebuildCachedRunBadges()
        debugSidebarLog(
            "rebuildCachedSidebarState durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "diffTotals=\(cachedDiffTotals.count) runBadges=\(cachedRunBadges.count)"
        )
    }

    private func rebuildCachedDiffTotals() {
        let fp = diffFingerprint
        guard fp != lastDiffFingerprint else { return }
        // Keep streaming smooth: diff totals are sidebar-only and can wait until active runs settle.
        guard !codex.hasAnyRunningTurn else {
            debugSidebarLog("rebuildCachedDiffTotals skipped runningTurn=true")
            return
        }
        let startedAt = Date()
        lastDiffFingerprint = fp

        let currentThreadIDs = Set(codex.threads.map(\.id))
        cachedDiffTotals = cachedDiffTotals.filter { currentThreadIDs.contains($0.key) }
        cachedDiffRevisionByThreadID = cachedDiffRevisionByThreadID.filter { currentThreadIDs.contains($0.key) }

        for thread in codex.threads {
            let revision = codex.messageRevision(for: thread.id)
            guard cachedDiffRevisionByThreadID[thread.id] != revision else { continue }

            let messages = codex.messages(for: thread.id)
            cachedDiffTotals[thread.id] = TurnSessionDiffSummaryCalculator.totals(
                from: messages,
                scope: .unpushedSession
            )
            cachedDiffRevisionByThreadID[thread.id] = revision
        }
        debugSidebarLog(
            "rebuildCachedDiffTotals durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "threadCount=\(codex.threads.count) cached=\(cachedDiffTotals.count)"
        )
    }

    private func rebuildCachedRunBadges() {
        let fp = badgeFingerprint
        guard fp != lastBadgeFingerprint else { return }
        let startedAt = Date()
        lastBadgeFingerprint = fp

        var byThreadID: [String: CodexThreadRunBadgeState] = [:]
        for thread in codex.threads {
            if let state = codex.threadRunBadgeState(for: thread.id) {
                byThreadID[thread.id] = state
            }
        }
        cachedRunBadges = byThreadID
        debugSidebarLog(
            "rebuildCachedRunBadges durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "threadCount=\(codex.threads.count) cached=\(cachedRunBadges.count)"
        )
    }

    // Keeps the chooser in sync with the same project buckets shown in the sidebar.
    private var newChatProjectChoices: [SidebarProjectChoice] {
        SidebarThreadGrouping.makeProjectChoices(from: codex.threads)
    }

    private var canCreateThread: Bool {
        codex.isConnected && codex.isInitialized
    }

    private func debugSidebarLog(_ message: String) {
        sidebarDebugSequence += 1
        print("[SidebarData] #\(sidebarDebugSequence) \(message)")
    }

    private var filteredV2Threads: [CodexV2ThreadSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return codexV2.timeline.threadSummaries
        }

        return codexV2.timeline.threadSummaries.filter { thread in
            thread.title.localizedCaseInsensitiveContains(query)
                || thread.preview.localizedCaseInsensitiveContains(query)
                || thread.threadID.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct SidebarV2WorkspaceButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticFeedback.shared.triggerImpactFeedback()
            action()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(AppFont.title3(weight: .regular))
                Text("Version 2.0")
                    .font(AppFont.body(weight: .medium))
                Spacer()
                if isSelected {
                    Text("Open")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color(.secondarySystemFill) : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarV2WorkspaceSummary: View {
    let isConnected: Bool
    let threadCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isConnected ? "V2 connected" : "V2 not connected")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)

            Text(threadCount == 0
                 ? "Open the V2 workspace and tap Refresh to load threads."
                 : "\(threadCount) V2 threads cached.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarV2ThreadSection: View {
    let threads: [CodexV2ThreadSummary]
    let selectedThreadID: String?
    let onSelectThread: (CodexV2ThreadSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("V2 Threads")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(threads, id: \.threadID) { thread in
                Button {
                    onSelectThread(thread)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(thread.title.isEmpty ? "Untitled Thread" : thread.title)
                                .font(AppFont.subheadline(weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            if thread.isRunning {
                                Text("Running")
                                    .font(AppFont.caption(weight: .semibold))
                                    .foregroundStyle(.orange)
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
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selectedThreadID == thread.threadID ? Color(.secondarySystemFill) : Color.primary.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

enum SidebarThreadsLoadingPresentation {
    // Keeps pull-to-refresh from stacking a second spinner over an already populated sidebar.
    static func shouldShowOverlay(isLoadingThreads: Bool, threadCount: Int) -> Bool {
        isLoadingThreads && threadCount == 0
    }
}

private struct SidebarNewChatProjectPickerSheet: View {
    let choices: [SidebarProjectChoice]
    let onSelectProject: (String) -> Void
    let onSelectWorktreeProject: (String) -> Void
    let onSelectWithoutProject: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose a project for this chat.")
                        .font(AppFont.body())
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Local") {
                    ForEach(choices) { choice in
                        Button {
                            dismiss()
                            onSelectProject(choice.projectPath)
                        } label: {
                            HStack(spacing: 12) {
                                if choice.iconSystemName == "arrow.triangle.branch" {
                                    CodexWorktreeIcon(pointSize: 16, weight: .medium)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: choice.iconSystemName)
                                        .font(AppFont.body(weight: .medium))
                                        .foregroundStyle(.secondary)
                                }

                                Text(choice.label)
                                    .font(AppFont.body(weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !choices.isEmpty {
                    Section("Worktree") {
                        ForEach(choices) { choice in
                            Button {
                                dismiss()
                                onSelectWorktreeProject(choice.projectPath)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    CodexWorktreeIcon(pointSize: 16, weight: .medium)
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(choice.label)
                                            .font(AppFont.body(weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Text("Start a new chat in a managed detached worktree from the repo default branch.")
                                            .font(AppFont.body())
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onSelectWithoutProject()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "cloud")
                                .font(AppFont.body(weight: .medium))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cloud")
                                    .font(AppFont.body(weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("Start a chat without a local working directory.")
                                    .font(AppFont.body())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    // Explains the existing scoping rule at the exact moment the user chooses it.
                    Text("Chats started in a project stay scoped to that working directory. Worktree chats start in a managed detached worktree. If you pick Cloud, the chat is global.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Start new chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents(choices.count > 4 ? [.medium, .large] : [.medium])
    }
}
