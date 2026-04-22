// FILE: CodexGPTAccountTests.swift
// Purpose: Verifies bridge-owned ChatGPT account state, login notifications, and voice transcription requests.
// Layer: Unit Test
// Exports: CodexGPTAccountTests
// Depends on: XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexGPTAccountTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testRefreshGPTAccountStateDecodesSanitizedBridgeStatus() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("user@example.com"),
                        "planType": .string("plus"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            }

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.authMethod, .chatgpt)
        XCTAssertEqual(service.gptAccountSnapshot.email, "user@example.com")
        XCTAssertEqual(service.gptAccountSnapshot.planType, "plus")
        XCTAssertFalse(service.gptAccountSnapshot.loginInFlight)
        XCTAssertTrue(service.gptAccountSnapshot.isVoiceTokenReady)
        XCTAssertNil(service.gptAccountErrorMessage)
    }

    func testRefreshGPTAccountStateFallsBackToLegacyGetAuthStatusPayload() async {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/status/read":
                XCTAssertNil(params)
                throw CodexServiceError.invalidInput("method not found")
            case "getAuthStatus":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "authMethod": .string("chatgptAuthTokens"),
                        "authToken": .string("legacy-token"),
                        "requiresOpenaiAuth": .bool(false),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        await service.refreshGPTAccountState()

        XCTAssertEqual(observedMethods, ["account/status/read", "getAuthStatus"])
        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.authMethod, .chatgpt)
        XCTAssertTrue(service.gptAccountSnapshot.isVoiceTokenReady)
        XCTAssertFalse(service.gptVoiceRequiresLogin)
    }

    func testRefreshBridgeVersionStatePresentsOptionalBridgeUpdateWhenLatestIsNewer() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("1.3.7"),
                    "bridgeLatestVersion": .string("1.3.8"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)

        XCTAssertEqual(service.bridgeInstalledVersion, "1.3.7")
        XCTAssertEqual(service.latestBridgePackageVersion, "1.3.8")
        XCTAssertEqual(
            service.bridgeUpdatePrompt?.title,
            "A newer Remodex update is available on your Mac"
        )
        XCTAssertEqual(service.bridgeUpdatePrompt?.command, "npm install -g remodex@latest")
        XCTAssertEqual(service.gptAccountSnapshot.status, .unknown)
    }

    func testRefreshBridgeVersionStateDoesNotPresentOptionalBridgeUpdateWithoutForegroundFlag() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("1.3.7"),
                    "bridgeLatestVersion": .string("1.3.8"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState()

        XCTAssertNil(service.bridgeUpdatePrompt)
    }

    func testRefreshBridgeVersionStateDoesNotRepeatOptionalBridgeUpdateForSameLatestVersion() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("1.3.7"),
                    "bridgeLatestVersion": .string("1.3.8"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)
        let firstPrompt = service.bridgeUpdatePrompt

        service.bridgeUpdatePrompt = nil
        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)

        XCTAssertNotNil(firstPrompt)
        XCTAssertNil(service.bridgeUpdatePrompt)
    }

    func testForegroundReturnRefreshesBridgeVersionAndPresentsOptionalUpdatePrompt() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.syncRealtimeEnabled = false
        service.isAppInForeground = false

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("1.3.7"),
                    "bridgeLatestVersion": .string("1.3.8"),
                ]),
                includeJSONRPC: false
            )
        }

        service.setForegroundState(true)
        await yieldMainActor(times: 3)

        XCTAssertEqual(service.bridgeInstalledVersion, "1.3.7")
        XCTAssertEqual(service.latestBridgePackageVersion, "1.3.8")
        XCTAssertEqual(
            service.bridgeUpdatePrompt?.title,
            "A newer Remodex update is available on your Mac"
        )
    }

    func testStartOrResumeGPTLoginUsesChatGPTVariantAndCachesPendingURL() async throws {
        let service = makeService()
        service.isConnected = true
        var capturedParams: JSONValue?

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/login/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "type": .string("chatgpt"),
                    "loginId": .string("login-123"),
                    "authUrl": .string("https://example.com/login"),
                ]),
                includeJSONRPC: false
            )
        }

        let loginResult = try await service.startOrResumeGPTLogin()

        XCTAssertEqual(capturedParams?.objectValue?["type"]?.stringValue, "chatgpt")
        XCTAssertEqual(loginResult.loginId, "login-123")
        XCTAssertEqual(loginResult.authURL.absoluteString, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testStartOrResumeGPTLoginOnMacOpensPendingBrowserOnBridge() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []
        var capturedOpenParams: IncomingParamsObject?

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/login/openOnMac":
                capturedOpenParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "success": .bool(true),
                        "openedOnMac": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        try await service.startOrResumeGPTLoginOnMac()

        XCTAssertEqual(observedMethods, ["account/login/start", "account/login/openOnMac"])
        XCTAssertEqual(capturedOpenParams?["authUrl"]?.stringValue, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testStartOrResumeGPTLoginOnPhoneReturnsAuthURLWithoutMacOpenRequest() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                XCTAssertEqual(params?.objectValue?["type"]?.stringValue, "chatgpt")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        let authURL = try await service.startOrResumeGPTLoginOnPhone()

        XCTAssertEqual(observedMethods, ["account/login/start"])
        XCTAssertEqual(authURL.absoluteString, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testLoginCompletedNotificationRefreshesAuthenticatedSnapshot() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("signedin@example.com"),
                        "planType": .string("plus"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/login/completed",
                params: .object([
                    "loginId": .string("login-123"),
                    "success": .bool(true),
                    "error": .null,
                ])
            )
        )

        await yieldMainActor(times: 3)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.email, "signedin@example.com")
        XCTAssertTrue(observedMethods.contains("account/status/read"))
    }

    func testAuthenticatedSnapshotWithoutTokenReadyKeepsVoiceDisabled() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "email": .string("user@example.com"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(false),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertFalse(service.gptAccountSnapshot.isVoiceTokenReady)
        XCTAssertFalse(service.canUseGPTVoiceTranscription)
        XCTAssertTrue(service.gptVoiceTemporarilyUnavailable)
    }

    func testRefreshGPTAccountStateClearsStalePendingLoginWhenBridgeIsAuthenticated() async throws {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("signedin@example.com"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        XCTAssertNotNil(service.currentPendingGPTLogin())

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertFalse(service.gptAccountSnapshot.loginInFlight)
        XCTAssertNil(service.currentPendingGPTLogin())
        XCTAssertFalse(service.gptVoiceRequiresLogin)
        XCTAssertTrue(service.canUseGPTVoiceTranscription)
    }

    func testAuthenticatedSnapshotWithoutTokenReadyEventuallyNeedsReauth() {
        let service = makeService()
        service.gptAccountSnapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "user@example.com",
            displayName: nil,
            planType: nil,
            loginInFlight: false,
            needsReauth: false,
            expiresAt: nil,
            tokenReady: false,
            tokenUnavailableSince: Date().addingTimeInterval(-90),
            updatedAt: .now
        )

        let snapshot = service.decodeBridgeGPTAccountSnapshot(from: [
            "status": .string("authenticated"),
            "authMethod": .string("chatgpt"),
            "email": .string("user@example.com"),
            "loginInFlight": .bool(false),
            "needsReauth": .bool(false),
            "tokenReady": .bool(false),
        ])

        XCTAssertEqual(snapshot.status, .authenticated)
        XCTAssertTrue(snapshot.needsReauth)
        XCTAssertFalse(snapshot.isVoiceTokenReady)
        XCTAssertTrue(snapshot.canLogout)
    }

    func testHandleGPTLoginCallbackCompletesPendingLoginThroughBridge() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []
        var capturedCompleteParams: IncomingParamsObject?

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/login/complete":
                capturedCompleteParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "ok": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        await service.handleGPTLoginCallbackURL(URL(string: "phodex://auth/gpt/callback?code=abc")!)

        XCTAssertTrue(observedMethods.contains("account/login/complete"))
        XCTAssertEqual(capturedCompleteParams?["loginId"]?.stringValue, "login-123")
        XCTAssertEqual(
            capturedCompleteParams?["callbackUrl"]?.stringValue,
            "phodex://auth/gpt/callback?code=abc"
        )
    }

    func testPersistedGPTAccountSnapshotRestoresOnInit() throws {
        let defaults = makeDefaults()
        let encoder = JSONEncoder()
        let snapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "persisted@example.com",
            displayName: nil,
            planType: "plus",
            loginInFlight: false,
            needsReauth: false,
            expiresAt: Date(timeIntervalSince1970: 1_742_000_000),
            updatedAt: .now
        )
        defaults.set(try encoder.encode(snapshot), forKey: "codex.gpt.accountSnapshot")

        let service = CodexService(defaults: defaults)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.email, "persisted@example.com")
        XCTAssertEqual(service.gptAccountSnapshot.planType, "plus")
    }

    func testVoiceRealtimeConfigReportsDisconnectedWhenBridgeIsOffline() async {
        let service = makeService()
        service.isConnected = false

        await XCTAssertThrowsErrorAsync({
            _ = try await service.resolveRealtimeVoiceConfig()
        }) { error in
            XCTAssertEqual(error.localizedDescription, "Connect to your Mac before using voice transcription.")
        }
    }

    func testVoiceRealtimeConfigDecodesBridgePayload() async throws {
        let service = makeService()
        service.isConnected = true

        var observedMethod: String?
        service.requestTransportOverride = { method, params in
            observedMethod = method
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "provider": .string("bailian_realtime"),
                    "websocketURL": .string("wss://dashscope.aliyuncs.com/api-ws/v1/realtime"),
                    "apiKey": .string("dashscope-test-key"),
                    "model": .string("qwen3-asr-flash-realtime"),
                    "language": .string("zh"),
                    "inputSampleRateHz": .integer(16_000),
                    "inputEncoding": .string("pcm16"),
                    "vadSilenceDurationMs": .integer(400),
                    "vadThreshold": .double(0.5),
                ]),
                includeJSONRPC: false
            )
        }

        let config = try await service.resolveRealtimeVoiceConfig()

        XCTAssertEqual(observedMethod, "voice/realtimeConfig")
        XCTAssertEqual(config.provider, "bailian_realtime")
        XCTAssertEqual(config.websocketURL.absoluteString, "wss://dashscope.aliyuncs.com/api-ws/v1/realtime")
        XCTAssertEqual(config.apiKey, "dashscope-test-key")
        XCTAssertEqual(config.model, "qwen3-asr-flash-realtime")
        XCTAssertEqual(config.language, "zh")
        XCTAssertEqual(config.inputSampleRateHz, 16_000)
        XCTAssertEqual(config.inputEncoding, "pcm16")
        XCTAssertEqual(config.vadSilenceDurationMs, 400)
        XCTAssertEqual(config.vadThreshold, 0.5)
    }

    func testUnsupportedVoiceBridgeAuthMarksBridgeSessionAsUnsupported() {
        let service = makeService()
        let error = CodexServiceError.rpcError(
            RPCError(
                code: -32600,
                message: "Invalid request: unknown variant `voice/realtimeConfig`, expected one of `initialize`, `thread/start`"
            )
        )

        XCTAssertTrue(service.consumeUnsupportedVoiceBridgeAuth(error))
        XCTAssertFalse(service.supportsBridgeVoiceAuth)
        XCTAssertEqual(service.classifyVoiceFailure(error), .bridgeSessionUnsupported)
    }

    func testResolvedVoiceRecoveryReturnsLatestReasonVerbatim() {
        let service = makeService()
        let reason = CodexVoiceFailureReason.providerSpecific(
            summary: "请先在 Mac 上配置百炼实时听写。",
            detail: "先在本地 bridge 环境里设置 `DASHSCOPE_API_KEY`，然后重新连接后再试。"
        )

        XCTAssertEqual(service.resolveVoiceRecoveryReason(reason), reason)
    }

    func testVoiceAuthUnavailableIsClassifiedAsReconnectRequired() {
        let service = makeService()
        let error = CodexServiceError.rpcError(
            RPCError(
                code: -32000,
                message: "Could not read ChatGPT session from the Mac runtime. Is the bridge running?",
                data: .object([
                    "errorCode": .string("auth_unavailable"),
                ])
            )
        )

        XCTAssertEqual(service.classifyVoiceFailure(error), .reconnectRequired)
    }

    func testVoiceRealtimeConfigMissingUsesSpecificRecoveryReason() {
        let service = makeService()
        let error = CodexServiceError.rpcError(
            RPCError(
                code: -32000,
                message: "Configure DASHSCOPE_API_KEY on the paired Mac before using Bailian realtime dictation.",
                data: .object([
                    "errorCode": .string("realtime_config_missing"),
                ])
            )
        )

        XCTAssertEqual(
            service.classifyVoiceFailure(error),
            .providerSpecific(
                summary: "请先在 Mac 上配置百炼实时听写。",
                detail: "先在本地 bridge 环境里设置 `DASHSCOPE_API_KEY`，然后重新连接后再试。"
            )
        )
    }

    func testSuccessfulLoginKeepsPollingUntilVoiceTokenIsReady() async throws {
        let service = makeService()
        service.isConnected = true
        var accountStatusReadCount = 0

        service.requestTransportOverride = { method, params in
            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                accountStatusReadCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("voice@example.com"),
                        "planType": .string("pro"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(accountStatusReadCount >= 2),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/login/completed",
                params: .object([
                    "loginId": .string("login-123"),
                    "success": .bool(true),
                    "error": .null,
                ])
            )
        )

        await yieldMainActor(times: 3)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.tokenReady, false)
        XCTAssertFalse(service.gptAccountSnapshot.needsReauth)
        XCTAssertNotNil(service.currentPendingGPTLogin())

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.tokenReady, true)
        XCTAssertFalse(service.gptAccountSnapshot.needsReauth)
        XCTAssertNil(service.currentPendingGPTLogin())
    }

    private func makeService() -> CodexService {
        let service = CodexService(defaults: makeDefaults())
        Self.retainedServices.append(service)
        return service
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CodexGPTAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func yieldMainActor(times: Int) async {
        for _ in 0..<times {
            await Task.yield()
        }
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        _ errorHandler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            errorHandler(error)
        }
    }
}
