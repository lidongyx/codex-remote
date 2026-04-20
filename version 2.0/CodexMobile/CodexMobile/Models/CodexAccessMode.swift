// FILE: CodexAccessMode.swift
// Purpose: Runtime permission mode for thread/turn operations.
// Layer: Model
// Exports: CodexAccessMode
// Depends on: Foundation

import Foundation

enum CodexAccessMode: String, Codable, CaseIterable, Hashable, Sendable {
    case onRequest = "on-request"
    case fullAccess = "full-access"

    var displayName: String {
        switch self {
        case .onRequest:
            return L10n.string("Ask")
        case .fullAccess:
            return L10n.string("Full")
        }
    }

    var menuTitle: String {
        switch self {
        case .onRequest:
            return L10n.string("On-Request")
        case .fullAccess:
            return L10n.string("Full Access")
        }
    }

    // Tries modern approval-policy enums first, then the bridge's kebab-case sandbox enum fallback.
    var approvalPolicyCandidates: [String] {
        switch self {
        case .onRequest:
            return ["on-request", "onRequest"]
        case .fullAccess:
            return ["never"]
        }
    }

    var sandboxLegacyValue: String {
        switch self {
        case .onRequest:
            return "workspace-write"
        case .fullAccess:
            return "danger-full-access"
        }
    }
}
