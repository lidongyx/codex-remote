// FILE: TurnComposerMetaMapper.swift
// Purpose: Centralizes model/reasoning/speed label mapping and ordering for TurnView composer menus.
// Layer: View Helper
// Exports: TurnComposerMetaMapper, TurnComposerReasoningDisplayOption
// Depends on: CodexModelOption, CodexServiceTier

import Foundation

// Keeps TurnView lightweight by isolating menu formatting/sorting rules.
enum TurnComposerMetaMapper {
    // ─── Model Mapping ────────────────────────────────────────────────

    // Returns models sorted using the explicit product order expected by the UI.
    nonisolated static func orderedModels(from models: [CodexModelOption]) -> [CodexModelOption] {
        let preferredOrder: [String] = [
            "gpt-5.1-codex-mini",
            "gpt-5.2",
            "gpt-5.1-codex-max",
            "gpt-5.2-codex",
            "gpt-5.3-codex",
        ]
        let rankByModel = Dictionary(uniqueKeysWithValues: preferredOrder.enumerated().map { index, value in
            (value, index)
        })

        return models.sorted { lhs, rhs in
            let lhsRank = rankByModel[lhs.model.lowercased()] ?? Int.max
            let rhsRank = rankByModel[rhs.model.lowercased()] ?? Int.max
            if lhsRank == rhsRank {
                return modelTitle(for: lhs) > modelTitle(for: rhs)
            }
            return lhsRank < rhsRank
        }
    }

    // Normalizes backend ids into consistent menu labels.
    nonisolated static func modelTitle(for model: CodexModelOption) -> String {
        switch model.model.lowercased() {
        case "gpt-5.3-codex":
            return "GPT-5.3-Codex"
        case "gpt-5.2-codex":
            return "GPT-5.2-Codex"
        case "gpt-5.1-codex-max":
            return "GPT-5.1-Codex-Max"
        case "gpt-5.4":
            return "GPT-5.4"
        case "gpt-5.2":
            return "GPT-5.2"
        case "gpt-5.1-codex-mini":
            return "GPT-5.1-Codex-Mini"
        default:
            return model.displayName
        }
    }

    // ─── Reasoning Mapping ───────────────────────────────────────────

    // Converts server effort values to user-facing labels and sorts them by level.
    nonisolated static func reasoningDisplayOptions(from efforts: [String]) -> [TurnComposerReasoningDisplayOption] {
        efforts
            .map { effort in
                TurnComposerReasoningDisplayOption(
                    effort: effort,
                    title: reasoningTitle(for: effort)
                )
            }
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.title > rhs.title
                }
                return lhs.rank > rhs.rank
            }
    }

    // Maps raw effort values to user-facing labels.
    nonisolated static func reasoningTitle(for effort: String) -> String {
        let normalized = effort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "minimal", "low":
            return L10n.string("Low")
        case "medium":
            return L10n.string("Medium")
        case "high":
            return L10n.string("High")
        case "xhigh", "extra_high", "extra-high", "very_high", "very-high":
            return L10n.string("Extra High")
        default:
            return normalized.split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    // ─── Speed Mapping ───────────────────────────────────────────────

    // Maps the optional speed selection into a stable user-facing title.
    nonisolated static func serviceTierTitle(for serviceTier: CodexServiceTier?) -> String {
        guard let serviceTier else {
            return L10n.string("Normal")
        }
        return serviceTier.displayName
    }
}

struct TurnComposerReasoningDisplayOption: Identifiable {
    let effort: String
    let title: String

    var id: String { effort }

    // Provides deterministic ordering for reasoning rows.
    nonisolated var rank: Int {
        switch title {
        case let value where value == L10n.string("Low"):
            return 0
        case let value where value == L10n.string("Medium"):
            return 1
        case let value where value == L10n.string("High"):
            return 2
        case let value where value == L10n.string("Exceptional"):
            return 3
        default:
            return 4
        }
    }
}
