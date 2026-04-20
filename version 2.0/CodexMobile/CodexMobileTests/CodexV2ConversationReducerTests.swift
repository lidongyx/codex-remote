// FILE: CodexV2ConversationReducerTests.swift
// Purpose: Verifies V2 preview chat projection keeps prompts, streaming deltas, and catch-up snapshots stable.
// Layer: Unit Test
// Exports: CodexV2ConversationReducerTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class CodexV2ConversationReducerTests: XCTestCase {
    func testOutgoingPromptMovesFromDraftBucketIntoStartedThread() {
        var state = CodexV2ConversationState()

        let pendingPrompt = CodexV2ConversationReducer.recordOutgoingPrompt(
            "Ship the V2 reconnect polish.",
            provisionalThreadID: nil,
            in: &state
        )

        XCTAssertEqual(
            state.messagesByThreadID[CodexV2ConversationReducer.pendingThreadKey]?.count,
            1
        )
        XCTAssertEqual(state.pendingPrompts.first?.id, pendingPrompt.id)

        CodexV2ConversationReducer.apply(
            .runStarted(
                threadID: "thread-v2",
                turnID: "turn-v2",
                globalSequence: 1,
                model: "gpt-5.4"
            ),
            to: &state
        )

        XCTAssertTrue(state.pendingPrompts.isEmpty)
        XCTAssertTrue(
            state.messagesByThreadID[CodexV2ConversationReducer.pendingThreadKey]?.isEmpty ?? true
        )
        XCTAssertEqual(state.messagesByThreadID["thread-v2"]?.count, 1)
        XCTAssertEqual(state.messagesByThreadID["thread-v2"]?.first?.turnID, "turn-v2")
        XCTAssertEqual(
            state.messagesByThreadID["thread-v2"]?.first?.text,
            "Ship the V2 reconnect polish."
        )
    }

    func testStreamingDeltasMergeIntoStableConversationRows() {
        var state = CodexV2ConversationState()

        CodexV2ConversationReducer.apply(
            .reasoning(
                threadID: "thread-v2",
                turnID: "turn-v2",
                globalSequence: 1,
                itemID: "think-1",
                delta: "Plan the reconnect flow."
            ),
            to: &state
        )
        CodexV2ConversationReducer.apply(
            .reasoning(
                threadID: "thread-v2",
                turnID: "turn-v2",
                globalSequence: 2,
                itemID: "think-1",
                delta: " Then restore the selected thread."
            ),
            to: &state
        )
        CodexV2ConversationReducer.apply(
            .assistantText(
                threadID: "thread-v2",
                turnID: "turn-v2",
                globalSequence: 3,
                delta: "Reconnect is now "
            ),
            to: &state
        )
        CodexV2ConversationReducer.apply(
            .assistantText(
                threadID: "thread-v2",
                turnID: "turn-v2",
                globalSequence: 4,
                delta: "stable."
            ),
            to: &state
        )
        CodexV2ConversationReducer.apply(
            .runCompletion(
                threadID: "thread-v2",
                turnID: "turn-v2",
                globalSequence: 5,
                result: "ok",
                errorMessage: ""
            ),
            to: &state
        )

        let messages = state.messagesByThreadID["thread-v2"] ?? []
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .reasoning)
        XCTAssertEqual(
            messages[0].text,
            "Plan the reconnect flow. Then restore the selected thread."
        )
        XCTAssertFalse(messages[0].isStreaming)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].text, "Reconnect is now stable.")
        XCTAssertFalse(messages[1].isStreaming)
    }

    func testRunCompletionWithoutAssistantDeltaFallsBackToErrorRow() {
        var state = CodexV2ConversationState()

        CodexV2ConversationReducer.apply(
            .runCompletion(
                threadID: "thread-v2",
                turnID: "turn-v2",
                globalSequence: 9,
                result: "",
                errorMessage: "The selected thread could not be restored."
            ),
            to: &state
        )

        let messages = state.messagesByThreadID["thread-v2"] ?? []
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .error)
        XCTAssertEqual(messages.first?.text, "The selected thread could not be restored.")
    }

    func testCatchupSnapshotIsStoredPerThread() {
        var state = CodexV2ConversationState()

        CodexV2ConversationReducer.apply(
            .threadCatchUpBatch(
                threadID: "thread-v2",
                latestThreadSequence: 41,
                events: [],
                hasMore: true
            ),
            to: &state
        )

        XCTAssertEqual(
            state.recoveryByThreadID["thread-v2"],
            CodexV2ThreadRecoverySnapshot(
                latestThreadSequence: 41,
                eventCount: 0,
                hasMore: true
            )
        )
    }

    func testCatchupBatchRebuildsConversationFromRecoveredEvents() {
        var state = CodexV2ConversationState()

        CodexV2ConversationReducer.apply(
            .threadCatchUpBatch(
                threadID: "thread-v2",
                latestThreadSequence: 5,
                events: [
                    CodexV2ThreadEvent(
                        sequence: 1,
                        payload: .userMessage(turnID: "turn-v2", text: "Ship the reconnect polish.")
                    ),
                    CodexV2ThreadEvent(
                        sequence: 2,
                        payload: .reasoningDelta(
                            turnID: "turn-v2",
                            itemID: "thinking-1",
                            delta: "Check the reconnect path."
                        )
                    ),
                    CodexV2ThreadEvent(
                        sequence: 3,
                        payload: .reasoningDelta(
                            turnID: "turn-v2",
                            itemID: "thinking-2",
                            delta: " Then restore the selected chat."
                        )
                    ),
                    CodexV2ThreadEvent(
                        sequence: 4,
                        payload: .assistantDelta(
                            turnID: "turn-v2",
                            delta: "Reconnect and recovery are ready."
                        )
                    ),
                    CodexV2ThreadEvent(
                        sequence: 5,
                        payload: .statusChanged(turnID: "turn-v2", status: "completed")
                    ),
                ],
                hasMore: false
            ),
            to: &state
        )

        let messages = state.messagesByThreadID["thread-v2"] ?? []
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "Ship the reconnect polish.")
        XCTAssertEqual(messages[1].role, .reasoning)
        XCTAssertEqual(
            messages[1].text,
            "Check the reconnect path. Then restore the selected chat."
        )
        XCTAssertFalse(messages[1].isStreaming)
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[2].text, "Reconnect and recovery are ready.")
        XCTAssertFalse(messages[2].isStreaming)
        XCTAssertEqual(
            state.recoveryByThreadID["thread-v2"],
            CodexV2ThreadRecoverySnapshot(
                latestThreadSequence: 5,
                eventCount: 5,
                hasMore: false
            )
        )
    }

    func testCatchupFailureStatusCreatesRecoveredErrorRow() {
        var state = CodexV2ConversationState()

        CodexV2ConversationReducer.apply(
            .threadCatchUpBatch(
                threadID: "thread-v2",
                latestThreadSequence: 2,
                events: [
                    CodexV2ThreadEvent(
                        sequence: 1,
                        payload: .userMessage(turnID: "turn-v2", text: "Retry the connection.")
                    ),
                    CodexV2ThreadEvent(
                        sequence: 2,
                        payload: .statusChanged(turnID: "turn-v2", status: "failed")
                    ),
                ],
                hasMore: false
            ),
            to: &state
        )

        let messages = state.messagesByThreadID["thread-v2"] ?? []
        XCTAssertEqual(messages.map(\.role), [.user, .error])
        XCTAssertEqual(messages.last?.text, "Run failed.")
    }
}
