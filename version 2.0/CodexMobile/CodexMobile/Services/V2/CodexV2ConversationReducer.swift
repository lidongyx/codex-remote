// FILE: CodexV2ConversationReducer.swift
// Purpose: Normalizes streamed V2 frames into chat-friendly per-thread conversation state.
// Layer: Service support
// Exports: CodexV2ConversationReducer

import Foundation

enum CodexV2ConversationReducer {
    static let pendingThreadKey = "__codex_v2_pending_thread__"

    static func normalizedThreadKey(_ threadID: String?) -> String {
        guard let threadID else {
            return pendingThreadKey
        }

        let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? pendingThreadKey : trimmed
    }

    @discardableResult
    static func recordOutgoingPrompt(
        _ text: String,
        provisionalThreadID: String?,
        in state: inout CodexV2ConversationState
    ) -> CodexV2PendingPrompt {
        let threadKey = normalizedThreadKey(provisionalThreadID)
        let item = CodexV2ConversationItem(
            id: "user-\(UUID().uuidString)",
            threadID: threadKey,
            turnID: nil,
            role: .user,
            text: text,
            isStreaming: false,
            reasoningItemID: nil
        )
        state.messagesByThreadID[threadKey, default: []].append(item)

        let pendingPrompt = CodexV2PendingPrompt(
            id: "pending-\(UUID().uuidString)",
            conversationItemID: item.id,
            threadID: threadKey
        )
        state.pendingPrompts.append(pendingPrompt)
        return pendingPrompt
    }

    static func apply(
        _ frame: CodexV2ServerFrame,
        to state: inout CodexV2ConversationState
    ) {
        switch frame {
        case let .runStarted(threadID, turnID, _, _):
            resolvePendingPrompt(threadID: threadID, turnID: turnID, in: &state)
        case let .reasoning(threadID, turnID, _, itemID, delta):
            appendStreamingDelta(
                threadID: threadID,
                turnID: turnID,
                role: .reasoning,
                delta: delta,
                reasoningItemID: itemID,
                in: &state
            )
        case let .assistantText(threadID, turnID, _, delta):
            appendStreamingDelta(
                threadID: threadID,
                turnID: turnID,
                role: .assistant,
                delta: delta,
                reasoningItemID: nil,
                in: &state
            )
        case let .runCompletion(threadID, turnID, _, result, errorMessage):
            markTurnFinished(threadID: threadID, turnID: turnID, in: &state)
            appendCompletionFallbackIfNeeded(
                threadID: threadID,
                turnID: turnID,
                result: result,
                errorMessage: errorMessage,
                in: &state
            )
        case let .threadCatchUpBatch(threadID, latestThreadSequence, events, hasMore):
            applyCatchUpBatch(
                threadID: threadID,
                latestThreadSequence: latestThreadSequence,
                events: events,
                hasMore: hasMore,
                in: &state
            )
        case .sessionReady, .threadListSnapshot, .error:
            break
        }
    }

    static func appendTransportError(
        code: String,
        message: String,
        threadID: String?,
        in state: inout CodexV2ConversationState
    ) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return
        }

        let threadKey = normalizedThreadKey(threadID)
        state.messagesByThreadID[threadKey, default: []].append(
            CodexV2ConversationItem(
                id: "transport-error-\(UUID().uuidString)",
                threadID: threadKey,
                turnID: nil,
                role: .error,
                text: "\(code)\n\(trimmedMessage)",
                isStreaming: false,
                reasoningItemID: nil
            )
        )
    }

    private static func resolvePendingPrompt(
        threadID: String,
        turnID: String,
        in state: inout CodexV2ConversationState
    ) {
        let threadKey = normalizedThreadKey(threadID)
        let matchingIndex = state.pendingPrompts.firstIndex(where: { $0.threadID == threadKey })
            ?? state.pendingPrompts.firstIndex(where: { $0.threadID == pendingThreadKey })

        guard let matchingIndex else {
            return
        }

        let pendingPrompt = state.pendingPrompts.remove(at: matchingIndex)

        if pendingPrompt.threadID == threadKey {
            updateMessage(
                itemID: pendingPrompt.conversationItemID,
                in: threadKey,
                state: &state
            ) { item in
                item.turnID = turnID
            }
            return
        }

        guard let pendingMessages = state.messagesByThreadID[pendingPrompt.threadID],
              let pendingMessageIndex = pendingMessages.firstIndex(where: { $0.id == pendingPrompt.conversationItemID }) else {
            return
        }

        var movedMessage = pendingMessages[pendingMessageIndex]
        movedMessage.threadID = threadKey
        movedMessage.turnID = turnID
        state.messagesByThreadID[pendingPrompt.threadID]?.remove(at: pendingMessageIndex)
        if state.messagesByThreadID[pendingPrompt.threadID]?.isEmpty == true {
            state.messagesByThreadID.removeValue(forKey: pendingPrompt.threadID)
        }
        state.messagesByThreadID[threadKey, default: []].append(movedMessage)
    }

    private static func appendStreamingDelta(
        threadID: String,
        turnID: String,
        role: CodexV2ConversationItemRole,
        delta: String,
        reasoningItemID: String?,
        in state: inout CodexV2ConversationState
    ) {
        guard !delta.isEmpty else {
            return
        }

        let threadKey = normalizedThreadKey(threadID)
        let itemID = messageIdentifier(
            role: role,
            turnID: turnID,
            reasoningItemID: reasoningItemID
        )

        if updateMessage(itemID: itemID, in: threadKey, state: &state, mutate: { item in
            item.text += delta
            item.isStreaming = true
        }) {
            return
        }

        if role == .reasoning,
           updateFirstMessage(in: threadKey, state: &state, matching: { item in
               item.role == .reasoning && item.turnID == turnID && item.isStreaming
           }, mutate: { item in
               item.text += delta
               item.isStreaming = true
               if item.reasoningItemID == nil {
                   item.reasoningItemID = reasoningItemID
               }
           }) {
            return
        }

        state.messagesByThreadID[threadKey, default: []].append(
            CodexV2ConversationItem(
                id: itemID,
                threadID: threadKey,
                turnID: turnID,
                role: role,
                text: delta,
                isStreaming: true,
                reasoningItemID: reasoningItemID
            )
        )
    }

    private static func appendCompletionFallbackIfNeeded(
        threadID: String,
        turnID: String,
        result: String,
        errorMessage: String,
        in state: inout CodexV2ConversationState
    ) {
        let threadKey = normalizedThreadKey(threadID)
        let trimmedError = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadMessages = state.messagesByThreadID[threadKey] ?? []
        let hasAssistantMessage = threadMessages.contains { item in
            item.turnID == turnID && item.role == .assistant
        }

        if !trimmedError.isEmpty {
            let itemID = messageIdentifier(role: .error, turnID: turnID, reasoningItemID: nil)
            let didUpdateError = updateMessage(itemID: itemID, in: threadKey, state: &state, mutate: { item in
                item.text = trimmedError
                item.isStreaming = false
            })
            if !didUpdateError {
                state.messagesByThreadID[threadKey, default: []].append(
                    CodexV2ConversationItem(
                        id: itemID,
                        threadID: threadKey,
                        turnID: turnID,
                        role: .error,
                        text: trimmedError,
                        isStreaming: false,
                        reasoningItemID: nil
                    )
                )
            }
            return
        }

        guard !trimmedResult.isEmpty, !hasAssistantMessage else {
            return
        }

        state.messagesByThreadID[threadKey, default: []].append(
            CodexV2ConversationItem(
                id: "completion-result-\(turnID)",
                threadID: threadKey,
                turnID: turnID,
                role: .assistant,
                text: trimmedResult,
                isStreaming: false,
                reasoningItemID: nil
            )
        )
    }

    private static func applyCatchUpBatch(
        threadID: String,
        latestThreadSequence: UInt64,
        events: [CodexV2ThreadEvent],
        hasMore: Bool,
        in state: inout CodexV2ConversationState
    ) {
        let threadKey = normalizedThreadKey(threadID)
        let previousSnapshot = state.recoveryByThreadID[threadKey]
        let isFreshRecovery = events.first?.sequence == 1
        if isFreshRecovery {
            state.messagesByThreadID[threadKey] = []
        }

        for event in events {
            applyCatchUpEvent(event, threadID: threadKey, in: &state)
        }

        state.recoveryByThreadID[threadKey] = CodexV2ThreadRecoverySnapshot(
            latestThreadSequence: latestThreadSequence,
            eventCount: (isFreshRecovery ? 0 : previousSnapshot?.eventCount ?? 0) + events.count,
            hasMore: hasMore
        )
    }

    private static func applyCatchUpEvent(
        _ event: CodexV2ThreadEvent,
        threadID: String,
        in state: inout CodexV2ConversationState
    ) {
        switch event.payload {
        case let .userMessage(turnID, text):
            appendRecoveredUserMessage(
                threadID: threadID,
                turnID: turnID,
                text: text,
                in: &state
            )
        case let .assistantDelta(turnID, delta):
            appendStreamingDelta(
                threadID: threadID,
                turnID: turnID,
                role: .assistant,
                delta: delta,
                reasoningItemID: nil,
                in: &state
            )
        case let .reasoningDelta(turnID, itemID, delta):
            appendStreamingDelta(
                threadID: threadID,
                turnID: turnID,
                role: .reasoning,
                delta: delta,
                reasoningItemID: itemID,
                in: &state
            )
        case .toolDelta:
            break
        case let .statusChanged(turnID, status):
            applyRecoveredStatusChange(
                threadID: threadID,
                turnID: turnID,
                status: status,
                in: &state
            )
        }
    }

    private static func appendRecoveredUserMessage(
        threadID: String,
        turnID: String,
        text: String,
        in state: inout CodexV2ConversationState
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        let itemID = messageIdentifier(role: .user, turnID: turnID, reasoningItemID: nil)
        if updateMessage(itemID: itemID, in: threadID, state: &state, mutate: { item in
            item.text = trimmedText
            item.isStreaming = false
        }) {
            return
        }

        if updateFirstMessage(in: threadID, state: &state, matching: { item in
            item.role == .user && item.turnID == turnID
        }, mutate: { item in
            item.text = trimmedText
            item.isStreaming = false
        }) {
            return
        }

        state.messagesByThreadID[threadID, default: []].append(
            CodexV2ConversationItem(
                id: itemID,
                threadID: threadID,
                turnID: turnID,
                role: .user,
                text: trimmedText,
                isStreaming: false,
                reasoningItemID: nil
            )
        )
    }

    private static func applyRecoveredStatusChange(
        threadID: String,
        turnID: String,
        status: String,
        in state: inout CodexV2ConversationState
    ) {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedStatus.isEmpty else {
            return
        }

        if normalizedStatus != "running" {
            markTurnFinished(threadID: threadID, turnID: turnID, in: &state)
        }

        switch normalizedStatus {
        case "failed":
            appendRecoveredErrorIfNeeded(
                threadID: threadID,
                turnID: turnID,
                message: "Run failed.",
                in: &state
            )
        case "stopped":
            appendRecoveredErrorIfNeeded(
                threadID: threadID,
                turnID: turnID,
                message: "Run stopped.",
                in: &state
            )
        default:
            break
        }
    }

    private static func appendRecoveredErrorIfNeeded(
        threadID: String,
        turnID: String,
        message: String,
        in state: inout CodexV2ConversationState
    ) {
        let threadKey = normalizedThreadKey(threadID)
        let itemID = messageIdentifier(role: .error, turnID: turnID, reasoningItemID: nil)
        if updateMessage(itemID: itemID, in: threadKey, state: &state, mutate: { item in
            item.text = message
            item.isStreaming = false
        }) {
            return
        }

        state.messagesByThreadID[threadKey, default: []].append(
            CodexV2ConversationItem(
                id: itemID,
                threadID: threadKey,
                turnID: turnID,
                role: .error,
                text: message,
                isStreaming: false,
                reasoningItemID: nil
            )
        )
    }

    private static func markTurnFinished(
        threadID: String,
        turnID: String,
        in state: inout CodexV2ConversationState
    ) {
        let threadKey = normalizedThreadKey(threadID)
        guard var threadMessages = state.messagesByThreadID[threadKey] else {
            return
        }

        for index in threadMessages.indices where threadMessages[index].turnID == turnID {
            threadMessages[index].isStreaming = false
        }

        state.messagesByThreadID[threadKey] = threadMessages
    }

    @discardableResult
    private static func updateMessage(
        itemID: String,
        in threadID: String,
        state: inout CodexV2ConversationState,
        mutate: (inout CodexV2ConversationItem) -> Void
    ) -> Bool {
        guard var threadMessages = state.messagesByThreadID[threadID],
              let messageIndex = threadMessages.firstIndex(where: { $0.id == itemID }) else {
            return false
        }

        mutate(&threadMessages[messageIndex])
        state.messagesByThreadID[threadID] = threadMessages
        return true
    }

    @discardableResult
    private static func updateFirstMessage(
        in threadID: String,
        state: inout CodexV2ConversationState,
        matching predicate: (CodexV2ConversationItem) -> Bool,
        mutate: (inout CodexV2ConversationItem) -> Void
    ) -> Bool {
        guard var threadMessages = state.messagesByThreadID[threadID],
              let messageIndex = threadMessages.firstIndex(where: predicate) else {
            return false
        }

        mutate(&threadMessages[messageIndex])
        state.messagesByThreadID[threadID] = threadMessages
        return true
    }

    private static func messageIdentifier(
        role: CodexV2ConversationItemRole,
        turnID: String,
        reasoningItemID: String?
    ) -> String {
        switch role {
        case .user:
            return "user-\(turnID)"
        case .assistant:
            return "assistant-\(turnID)"
        case .reasoning:
            return "reasoning-\(turnID)-\(reasoningItemID ?? "thinking")"
        case .error:
            return "error-\(turnID)"
        }
    }
}
