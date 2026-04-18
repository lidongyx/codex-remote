// FILE: CodexService+Notifications.swift
// Purpose: Manages local notification permission, background run-completion alerts, and tap routing.
// Layer: Service
// Exports: CodexService notification helpers
// Depends on: UserNotifications, CodexService+Messages

import Foundation
import UserNotifications

private enum CodexNotificationSource {
    static let runCompletion = "codex.runCompletion"
    static let structuredUserInput = "codex.structuredUserInput"
}

protocol CodexUserNotificationCentering: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func authorizationStatus() async -> UNAuthorizationStatus
}

extension UNUserNotificationCenter: CodexUserNotificationCentering {
    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await notificationSettings()
        return settings.authorizationStatus
    }
}

final class CodexNotificationCenterDelegateProxy: NSObject, UNUserNotificationCenterDelegate {
    weak var service: CodexService?

    init(service: CodexService) {
        self.service = service
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The in-app timeline and run badges already explain the new state.
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let service,
              let payload = CodexThreadNotificationPayload(from: response.notification.request.content.userInfo) else {
            return
        }

        await MainActor.run {
            service.handleNotificationOpen(threadId: payload.threadId, turnId: payload.turnId)
        }
    }
}

private struct CodexThreadNotificationPayload {
    let threadId: String
    let turnId: String?

    init?(from userInfo: [AnyHashable: Any]) {
        guard let source = userInfo[CodexNotificationPayloadKeys.source] as? String,
              (source == CodexNotificationSource.runCompletion
                || source == CodexNotificationSource.structuredUserInput),
              let threadId = userInfo[CodexNotificationPayloadKeys.threadId] as? String,
              !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        self.threadId = threadId
        self.turnId = userInfo[CodexNotificationPayloadKeys.turnId] as? String
    }
}

extension CodexService {
    // Wires the UNUserNotificationCenter delegate once so taps can reopen the right thread.
    func configureNotifications() {
        guard !hasConfiguredNotifications else {
            return
        }

        let delegateProxy = CodexNotificationCenterDelegateProxy(service: self)
        notificationCenterDelegateProxy = delegateProxy
        userNotificationCenter.delegate = delegateProxy
        hasConfiguredNotifications = true

        Task { @MainActor [weak self] in
            await self?.refreshManagedNotificationRegistrationState()
        }
    }

    // Requests notification permission once on first launch, while still allowing manual retry from Settings.
    func requestNotificationPermissionOnFirstLaunchIfNeeded() async {
        let promptedAlready = defaults.bool(forKey: Self.notificationsPromptedDefaultsKey)
        guard !promptedAlready else {
            await refreshManagedNotificationRegistrationState()
            return
        }

        await requestNotificationPermission(markPrompted: true)
    }

    // Used by: SettingsView, CodexMobileApp
    func requestNotificationPermission(markPrompted: Bool = true) async {
        do {
            _ = try await userNotificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            debugRuntimeLog("notification permission request failed: \(error.localizedDescription)")
        }

        if markPrompted {
            defaults.set(true, forKey: Self.notificationsPromptedDefaultsKey)
        }

        await refreshManagedNotificationRegistrationState()
    }

    func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await userNotificationCenter.authorizationStatus()
    }

    // Re-checks local notification permission after app launch or Settings changes.
    func refreshManagedNotificationRegistrationState() async {
        await refreshNotificationAuthorizationStatus()
    }

    // Schedules a local alert only when a run finishes while the app is away from the foreground.
    func notifyRunCompletionIfNeeded(threadId: String, turnId: String?, result: CodexRunCompletionResult) {
        guard !isAppInForeground else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.scheduleRunCompletionNotificationIfNeeded(
                threadId: threadId,
                turnId: turnId,
                result: result
            )
        }
    }

    // Prompts can arrive mid-turn without any terminal event, so surface them with a local alert
    // when the app is backgrounded instead of making the user rediscover them later in the timeline.
    func notifyStructuredUserInputIfNeeded(
        threadId: String,
        turnId: String?,
        requestID: JSONValue,
        questions: [CodexStructuredUserInputQuestion]
    ) {
        guard !isAppInForeground else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.scheduleStructuredUserInputNotificationIfNeeded(
                threadId: threadId,
                turnId: turnId,
                requestID: requestID,
                questions: questions
            )
        }
    }

    func handleNotificationOpen(threadId: String, turnId: String?) {
        let normalizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadId.isEmpty else {
            return
        }

        pendingNotificationOpenThreadID = normalizedThreadId
        Task { @MainActor [weak self] in
            guard let self else { return }

            let routed = await routePendingNotificationOpenIfPossible()
            if !routed,
               turnId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                debugRuntimeLog("notification target turn deferred thread=\(normalizedThreadId) turn=\(turnId ?? "")")
            }
        }
    }
}

extension CodexService {
    // Keeps push-tap intent alive across reconnect so cold-launch opens can resolve later.
    @discardableResult
    func routePendingNotificationOpenIfPossible(refreshIfNeeded: Bool = true) async -> Bool {
        guard let pendingThreadId = pendingNotificationOpenThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !pendingThreadId.isEmpty else {
            return false
        }

        if hasNotificationRoutingCandidate(threadId: pendingThreadId) {
            missingNotificationThreadPrompt = nil
            if await prepareThreadForDisplay(threadId: pendingThreadId) {
                if pendingNotificationOpenThreadID == pendingThreadId {
                    pendingNotificationOpenThreadID = nil
                }
                return true
            }
            if hasNotificationRoutingCandidate(threadId: pendingThreadId) {
                return false
            }
        }

        guard isConnected else {
            return false
        }

        let didRefreshThreads: Bool
        if refreshIfNeeded {
            didRefreshThreads = await refreshThreadsForNotificationRouting()
        } else {
            didRefreshThreads = true
        }

        guard hasNotificationRoutingCandidate(threadId: pendingThreadId) else {
            guard didRefreshThreads else {
                return false
            }
            return finalizeMissingNotificationRouteIfNeeded(
                threadId: pendingThreadId,
                isAuthoritativeMissingResult: isNotificationRouteKnownMissing(threadId: pendingThreadId)
            )
        }

        missingNotificationThreadPrompt = nil
        if await prepareThreadForDisplay(threadId: pendingThreadId) {
            if pendingNotificationOpenThreadID == pendingThreadId {
                pendingNotificationOpenThreadID = nil
            }
            return true
        }

        if !hasNotificationRoutingCandidate(threadId: pendingThreadId), didRefreshThreads {
            return finalizeMissingNotificationRouteIfNeeded(
                threadId: pendingThreadId,
                isAuthoritativeMissingResult: isNotificationRouteKnownMissing(threadId: pendingThreadId)
            )
        }

        return false
    }
}

private extension CodexService {
    // Only live threads can satisfy a notification open; archived placeholders mean the server rejected it.
    func hasNotificationRoutingCandidate(threadId: String) -> Bool {
        guard let thread = thread(for: threadId) else {
            return false
        }

        return thread.syncState != .archivedLocal
    }

    // `thread/list` can omit still-live threads, so only an explicit archived placeholder is authoritative.
    func isNotificationRouteKnownMissing(threadId: String) -> Bool {
        thread(for: threadId)?.syncState == .archivedLocal
    }

    // Consumes the pending deep-link only after a fresh thread refresh confirms the target is gone.
    func finalizeMissingNotificationRouteIfNeeded(
        threadId: String,
        isAuthoritativeMissingResult: Bool
    ) -> Bool {
        guard isAuthoritativeMissingResult else {
            return false
        }

        if pendingNotificationOpenThreadID == threadId {
            pendingNotificationOpenThreadID = nil
        }
        if activeThreadId == nil || activeThreadId == threadId {
            activeThreadId = firstLiveThreadID()
        }
        missingNotificationThreadPrompt = CodexMissingNotificationThreadPrompt(threadId: threadId)
        return false
    }

    // Keeps local alerts deduped because some runtimes emit both turn/completed and thread/status terminal signals.
    func scheduleRunCompletionNotificationIfNeeded(
        threadId: String,
        turnId: String?,
        result: CodexRunCompletionResult
    ) async {
        await refreshNotificationAuthorizationStatus()
        guard canScheduleRunCompletionNotifications else {
            return
        }

        let now = Date()
        pruneRunCompletionNotificationDedupe(now: now)
        let dedupeKey = runCompletionNotificationDedupeKey(
            threadId: threadId,
            turnId: turnId,
            result: result,
            now: now
        )

        if let previousTimestamp = runCompletionNotificationDedupedAt[dedupeKey],
           now.timeIntervalSince(previousTimestamp) <= 60 {
            return
        }

        runCompletionNotificationDedupedAt[dedupeKey] = now

        let title = thread(for: threadId)?.displayTitle ?? CodexThread.defaultDisplayTitle
        let body: String = {
            switch result {
            case .completed:
                "Response ready"
            case .failed:
                "Run failed"
            }
        }()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadId
        content.userInfo = [
            CodexNotificationPayloadKeys.source: CodexNotificationSource.runCompletion,
            CodexNotificationPayloadKeys.threadId: threadId,
            CodexNotificationPayloadKeys.turnId: turnId ?? "",
            CodexNotificationPayloadKeys.result: result.rawValue,
        ]

        let request = UNNotificationRequest(
            identifier: runCompletionNotificationIdentifier(for: dedupeKey),
            content: content,
            trigger: nil
        )

        do {
            try await userNotificationCenter.add(request)
        } catch {
            debugRuntimeLog("failed to schedule local notification: \(error.localizedDescription)")
        }
    }

    // Keeps repeated request replays from spamming duplicate alerts while a prompt is still pending.
    func scheduleStructuredUserInputNotificationIfNeeded(
        threadId: String,
        turnId: String?,
        requestID: JSONValue,
        questions: [CodexStructuredUserInputQuestion]
    ) async {
        await refreshNotificationAuthorizationStatus()
        guard canScheduleRunCompletionNotifications else {
            return
        }

        let now = Date()
        pruneStructuredUserInputNotificationDedupe(now: now)
        let dedupeKey = structuredUserInputNotificationDedupeKey(
            threadId: threadId,
            requestID: requestID
        )

        if let previousTimestamp = structuredUserInputNotificationDedupedAt[dedupeKey],
           now.timeIntervalSince(previousTimestamp) <= 60 {
            return
        }

        structuredUserInputNotificationDedupedAt[dedupeKey] = now

        let title = thread(for: threadId)?.displayTitle ?? CodexThread.defaultDisplayTitle
        let promptCount = questions.count
        let body = promptCount == 1
            ? "Codex needs one answer to continue."
            : "Codex needs \(promptCount) answers to continue."

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadId
        content.userInfo = [
            CodexNotificationPayloadKeys.source: CodexNotificationSource.structuredUserInput,
            CodexNotificationPayloadKeys.threadId: threadId,
            CodexNotificationPayloadKeys.turnId: turnId ?? "",
            CodexNotificationPayloadKeys.requestId: idKey(from: requestID),
        ]

        let request = UNNotificationRequest(
            identifier: structuredUserInputNotificationIdentifier(for: dedupeKey),
            content: content,
            trigger: nil
        )

        do {
            try await userNotificationCenter.add(request)
        } catch {
            debugRuntimeLog("failed to schedule structured user input notification: \(error.localizedDescription)")
        }
    }

    var canScheduleRunCompletionNotifications: Bool {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        case .denied, .notDetermined:
            false
        @unknown default:
            false
        }
    }
    func runCompletionNotificationDedupeKey(
        threadId: String,
        turnId: String?,
        result: CodexRunCompletionResult,
        now: Date
    ) -> String {
        if let turnId, !turnId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(threadId)|\(turnId)|\(result.rawValue)"
        }

        let timeBucket = Int(now.timeIntervalSince1970 / 30)
        return "\(threadId)|\(result.rawValue)|\(timeBucket)"
    }

    func runCompletionNotificationIdentifier(for dedupeKey: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(dedupeKey.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return "codex.runCompletion.\(sanitized)"
    }

    func pruneRunCompletionNotificationDedupe(now: Date) {
        runCompletionNotificationDedupedAt = runCompletionNotificationDedupedAt.filter { _, timestamp in
            now.timeIntervalSince(timestamp) <= 60
        }
    }

    func structuredUserInputNotificationDedupeKey(
        threadId: String,
        requestID: JSONValue
    ) -> String {
        "\(threadId)|\(idKey(from: requestID))"
    }

    func structuredUserInputNotificationIdentifier(for dedupeKey: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(dedupeKey.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return "codex.structuredUserInput.\(sanitized)"
    }

    func pruneStructuredUserInputNotificationDedupe(now: Date) {
        structuredUserInputNotificationDedupedAt = structuredUserInputNotificationDedupedAt.filter { _, timestamp in
            now.timeIntervalSince(timestamp) <= 60
        }
    }

    // Refreshes the thread list before routing a notification tap to a thread created on another client.
    func refreshThreadsForNotificationRouting() async -> Bool {
        guard isConnected else {
            return false
        }

        do {
            try await listThreads()
            return true
        } catch {
            debugRuntimeLog("thread refresh for notification routing failed: \(error.localizedDescription)")
            return false
        }
    }
}
