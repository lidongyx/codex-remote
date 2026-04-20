// FILE: CodexServiceTier.swift
// Purpose: User-selectable service tier for Codex app-server speed controls.
// Layer: Model
// Exports: CodexServiceTier
// Depends on: Foundation

import Foundation

enum CodexServiceTier: String, CaseIterable, Codable, Hashable, Sendable {
    case fast

    var displayName: String {
        switch self {
        case .fast:
            return L10n.string("Fast")
        }
    }

    var description: String {
        switch self {
        case .fast:
            return L10n.string("Lower latency using Codex Fast Mode.")
        }
    }

    var iconName: String {
        switch self {
        case .fast:
            return "bolt.fill"
        }
    }
}
