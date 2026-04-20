// FILE: L10n.swift
// Purpose: Centralized localization helpers for SwiftUI and Foundation call sites.
// Layer: Localization
// Exports: L10n
// Depends on: Foundation, SwiftUI

import Foundation
import SwiftUI

enum L10n {
    nonisolated static func key(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }

    nonisolated static func string(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    nonisolated static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: AppLanguage.current.locale, arguments: arguments)
    }

    private nonisolated static var localizedBundle: Bundle {
        switch AppLanguage.current {
        case .system:
            return .main
        case .english, .simplifiedChinese:
            guard let languageCode = AppLanguage.current.localizationCode,
                  let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return .main
            }
            return bundle
        }
    }
}
