// FILE: CodexMobileApp.swift
// Purpose: App entry point and root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import SwiftUI

@MainActor
@main
struct CodexMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.defaultStoredRawValue
    @State private var codexService: CodexService
    @State private var codexV2PreviewClient: CodexV2PreviewClient

    init() {
        let service = CodexService()
        service.configureNotifications()
        _codexService = State(initialValue: service)
        _codexV2PreviewClient = State(initialValue: CodexV2PreviewClient())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(codexService)
                .environment(codexV2PreviewClient)
                .environment(\.locale, selectedAppLanguage.locale)
                .onOpenURL { url in
                    Task { @MainActor in
                        guard CodexService.legacyGPTLoginCallbackEnabled else {
                            return
                        }
                        await codexService.handleGPTLoginCallbackURL(url)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    TurnCacheManager.resetAll()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else { return }
                    TurnCacheManager.resetAll()
                }
        }
    }

    private var selectedAppLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }
}
