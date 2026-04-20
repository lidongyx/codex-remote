// FILE: TurnComposerRuntimeState.swift
// Purpose: Bundles the composer runtime selection state shared by the bottom bar and input context menu.
// Layer: View Helper
// Exports: TurnComposerRuntimeState
// Depends on: CodexService, TurnComposerMetaMapper, CodexServiceTier

import Foundation

struct TurnComposerRuntimeState {
    let reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    let effectiveReasoningEffort: String?
    let selectedReasoningEffort: String?
    let reasoningMenuDisabled: Bool
    let selectedServiceTier: CodexServiceTier?

    var selectedReasoningTitle: String {
        let reasoningTitle: String
        if let effectiveReasoningEffort {
            reasoningTitle = TurnComposerMetaMapper.reasoningTitle(for: effectiveReasoningEffort)
        } else {
            reasoningTitle = L10n.string("Select reasoning")
        }

        guard let selectedServiceTier else {
            return reasoningTitle
        }

        return "\(reasoningTitle) · \(selectedServiceTier.displayName)"
    }

    func isSelectedReasoning(_ effort: String) -> Bool {
        (selectedReasoningEffort ?? effectiveReasoningEffort) == effort
    }

    func isSelectedServiceTier(_ serviceTier: CodexServiceTier?) -> Bool {
        selectedServiceTier == serviceTier
    }

    static func resolve(
        codex: CodexService,
        reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    ) -> TurnComposerRuntimeState {
        return TurnComposerRuntimeState(
            reasoningDisplayOptions: reasoningDisplayOptions,
            effectiveReasoningEffort: codex.selectedReasoningEffortForSelectedModel(),
            selectedReasoningEffort: codex.selectedReasoningEffort,
            reasoningMenuDisabled: reasoningDisplayOptions.isEmpty || codex.selectedModelOption() == nil,
            selectedServiceTier: codex.selectedServiceTier
        )
    }
}
