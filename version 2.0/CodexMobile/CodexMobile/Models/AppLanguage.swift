// FILE: AppLanguage.swift
// Purpose: Centralized app language preference with system-default fallback.
// Layer: Model
// Exports: AppLanguage
// Depends on: Foundation

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    nonisolated static let storageKey = "codex.appLanguage"
    nonisolated static let defaultStoredRawValue = AppLanguage.system.rawValue

    var id: String { rawValue }

    nonisolated static var current: AppLanguage {
        let storedValue = UserDefaults.standard.string(forKey: storageKey) ?? defaultStoredRawValue
        return AppLanguage(rawValue: storedValue) ?? .system
    }

    nonisolated var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }

    nonisolated var localizationCode: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .system:
            return L10n.string("System Default")
        case .english:
            return L10n.string("English")
        case .simplifiedChinese:
            return L10n.string("Simplified Chinese")
        }
    }
}
