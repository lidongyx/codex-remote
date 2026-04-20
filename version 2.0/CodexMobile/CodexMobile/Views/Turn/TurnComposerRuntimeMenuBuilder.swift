// FILE: TurnComposerRuntimeMenuBuilder.swift
// Purpose: Builds the UIKit edit-menu entries for the composer runtime controls.
// Layer: View Helper
// Exports: TurnComposerRuntimeMenuBuilder
// Depends on: UIKit, TurnComposerRuntimeState, TurnComposerRuntimeActions

import UIKit

struct TurnComposerRuntimeMenuBuilder {
    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions

    func makeRuntimeMenu() -> UIMenu? {
        var children: [UIMenuElement] = []

        if let reasoningMenu = makeReasoningMenu() {
            children.append(reasoningMenu)
        }

        children.append(makeSpeedMenu())

        guard !children.isEmpty else {
            return nil
        }

        return UIMenu(
            title: L10n.string("Chat Runtime"),
            image: UIImage(systemName: "slider.horizontal.3"),
            children: children
        )
    }

    // Keeps the text-edit menu aligned with the global reasoning controls shown in the bottom bar.
    private func makeReasoningMenu() -> UIMenu? {
        guard !runtimeState.reasoningDisplayOptions.isEmpty else {
            return nil
        }

        let children = runtimeState.reasoningDisplayOptions.map { option in
            UIAction(
                title: option.title,
                state: runtimeState.isSelectedReasoning(option.effort) ? .on : .off
            ) { _ in
                runtimeActions.selectReasoning(option.effort)
            }
        }

        return UIMenu(
            title: L10n.string("Reasoning"),
            image: UIImage(systemName: "brain"),
            children: children
        )
    }

    // Mirrors the composer speed control so long-press editing keeps the same runtime access.
    private func makeSpeedMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(
                title: TurnComposerMetaMapper.serviceTierTitle(for: nil),
                state: runtimeState.isSelectedServiceTier(nil) ? .on : .off
            ) { _ in
                runtimeActions.selectServiceTier(nil)
            }
        ]

        children.append(
            contentsOf: CodexServiceTier.allCases.map { serviceTier in
                UIAction(
                    title: serviceTier.displayName,
                    image: UIImage(systemName: serviceTier.iconName),
                    state: runtimeState.isSelectedServiceTier(serviceTier) ? .on : .off
                ) { _ in
                    runtimeActions.selectServiceTier(serviceTier)
                }
            }
        )

        return UIMenu(
            title: L10n.string("Speed"),
            image: UIImage(systemName: "bolt.fill"),
            children: children
        )
    }
}
