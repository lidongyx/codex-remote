// FILE: AboutRemodexView.swift
// Purpose: Full-screen connection guides for the legacy bridge flow and the V2 beta flow.
// Layer: View
// Exports: AboutRemodexView, RemodexConnectionGuideMode

import SwiftUI

enum RemodexConnectionGuideMode: Identifiable {
    case legacy
    case v2

    var id: String { navigationTitleKey }

    var navigationTitleKey: String {
        switch self {
        case .legacy:
            return "How To Connect - Method 1"
        case .v2:
            return "How To Connect - Method 2"
        }
    }

    var heroTitleKey: String {
        switch self {
        case .legacy:
            return "Method 1"
        case .v2:
            return "Method 2"
        }
    }

    var heroSubtitleKey: String {
        switch self {
        case .legacy:
            return "Local-first bridge (shipping today)"
        case .v2:
            return "V2 beta (`codexd` + V2 relay)"
        }
    }

    var heroCallout: ConnectionGuideCallout {
        switch self {
        case .legacy:
            return ConnectionGuideCallout(
                icon: "iphone.and.arrow.forward",
                color: .cyan,
                textKey: "Method 1 is the shipping local-first path: your iPhone controls Codex running on your Mac through saved relay pairing and QR/manual recovery."
            )
        case .v2:
            return ConnectionGuideCallout(
                icon: "arrow.triangle.branch",
                color: .orange,
                textKey: "Method 2 is a separate beta connection stack. It does not reuse the legacy bridge flow or its saved pairing."
            )
        }
    }

    var sections: [ConnectionGuideSection] {
        switch self {
        case .legacy:
            return [
                ConnectionGuideSection(
                    titleKey: "What It Uses",
                    bodyKeys: [
                        "Method 1 is the current shipping connection flow in Remodex. It keeps the runtime and workspace on your Mac."
                    ],
                    bulletKeys: [
                        "The iPhone app",
                        "Saved relay pairing plus QR/manual recovery",
                        "The `remodex` / `phodex-bridge` bridge running on your Mac",
                        "The local `codex app-server` behind that bridge",
                    ]
                ),
                ConnectionGuideSection(
                    titleKey: "How To Connect",
                    bulletKeys: [
                        "Start the bridge locally on your Mac.",
                        "Scan the QR code or enter the pairing code on your iPhone.",
                        "After the first trust handshake, your iPhone saves that Mac as the Method 1 pair.",
                        "Later reconnects prefer the saved pairing and resolve the live bridge session automatically.",
                    ],
                    callout: ConnectionGuideCallout(
                        icon: "checkmark.shield.fill",
                        color: .green,
                        textKey: "Open-source builds do not assume a hosted production relay. Method 1 uses the relay you paired or explicitly configured."
                    )
                ),
                ConnectionGuideSection(
                    titleKey: "What Actually Happens",
                    bodyKeys: [
                        "Method 1 keeps execution on the Mac and reuses the same Codex thread across devices."
                    ],
                    bulletKeys: [
                        "The iPhone talks to the bridge through the relay, then the bridge forwards requests to `codex app-server`.",
                        "Thread history is persisted under `~/.codex/sessions/` on the Mac.",
                        "`Hand off to Mac` opens that same thread in Codex.app.",
                        "If the thread keeps running on desktop, the bridge can mirror new rollout activity back to the iPhone.",
                    ],
                    callout: ConnectionGuideCallout(
                        icon: "macbook.and.iphone",
                        color: .blue,
                        textKey: "Method 1 is not screen mirroring and not repo syncing. The phone is controlling the Mac runtime for the same thread."
                    )
                ),
                ConnectionGuideSection(
                    titleKey: "What Bridge Version Means",
                    bodyKeys: [
                        "Bridge Version in Settings shows the Remodex bridge package version running on the paired Mac, not the iPhone app version.",
                        "`Installed on Mac` is the package currently running on your Mac. `Latest available` is the newest npm release the app could check.",
                    ]
                ),
                ConnectionGuideSection(
                    titleKey: "Compatibility",
                    bodyKeys: [
                        "Method 1 stays separate from Method 2."
                    ],
                    bulletKeys: [
                        "Its saved pairing does not automatically open the V2 beta workspace.",
                        "Method 1 remains the stable/default path even if Method 2 is enabled in Settings.",
                    ]
                ),
            ]
        case .v2:
            return [
                ConnectionGuideSection(
                    titleKey: "What It Uses",
                    bodyKeys: [
                        "Method 2 is the beta path built around the new V2 runtime."
                    ],
                    bulletKeys: [
                        "The iPhone V2 workspace entry",
                        "The `codexd` daemon on your Mac",
                        "The V2 relay",
                        "Separate V2 debug tools for validation",
                    ]
                ),
                ConnectionGuideSection(
                    titleKey: "How To Connect",
                    bulletKeys: [
                        "Open Method 2 from Settings in the app.",
                        "Start the V2 daemon/runtime on your Mac.",
                        "Connect and refresh chats through the Method 2 workspace.",
                        "Use `Open Method 2 Debug` if you need to validate the relay or daemon state.",
                    ],
                    callout: ConnectionGuideCallout(
                        icon: "wrench.and.screwdriver.fill",
                        color: .orange,
                        textKey: "Method 2 has its own workspace entry and troubleshooting tools."
                    )
                ),
                ConnectionGuideSection(
                    titleKey: "How It Differs From Method 1",
                    bodyKeys: [
                        "Method 2 is not a skin or minor upgrade over the legacy bridge."
                    ],
                    bulletKeys: [
                        "Different daemon: `codexd` instead of the Node.js bridge",
                        "Different relay/session model",
                        "Separate workspace entry, reconnect path, and debug surface",
                    ]
                ),
                ConnectionGuideSection(
                    titleKey: "Compatibility",
                    bodyKeys: [
                        "The V2 architecture in this repo explicitly ignores backward compatibility with the current shipping stack."
                    ],
                    bulletKeys: [
                        "Treat Method 2 as a separate beta connection flow.",
                        "Do not assume Method 1 pairing, reconnect state, or recovery steps apply to Method 2.",
                    ]
                ),
            ]
        }
    }
}

struct ConnectionGuideSection: Identifiable {
    let titleKey: String
    var bodyKeys: [String] = []
    var bulletKeys: [String] = []
    var callout: ConnectionGuideCallout? = nil

    var id: String { titleKey }
}

struct ConnectionGuideCallout {
    let icon: String
    let color: Color
    let textKey: String
}

struct AboutRemodexView: View {
    @Environment(\.dismiss) private var dismiss

    let mode: RemodexConnectionGuideMode

    init(mode: RemodexConnectionGuideMode = .legacy) {
        self.mode = mode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    ForEach(Array(mode.sections.enumerated()), id: \.element.id) { index, section in
                        sectionView(section)
                        if index < mode.sections.count - 1 {
                            Divider().opacity(0.3)
                        }
                    }

                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .font(AppFont.body())
            .navigationTitle(L10n.string(mode.navigationTitleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string(mode.heroTitleKey))
                .font(AppFont.headline(weight: .bold))
                .foregroundStyle(.primary)

            Text(L10n.key(mode.heroSubtitleKey))
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)

            calloutCard(mode.heroCallout)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func sectionView(_ section: ConnectionGuideSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string(section.titleKey))
                .font(AppFont.headline(weight: .semibold))
                .foregroundStyle(.primary)

            ForEach(section.bodyKeys, id: \.self) { key in
                bodyText(key)
            }

            if !section.bulletKeys.isEmpty {
                bulletList(section.bulletKeys)
            }

            if let callout = section.callout {
                calloutCard(callout)
            }
        }
    }

    @ViewBuilder
    private func bodyText(_ key: String) -> some View {
        Text(L10n.key(key))
            .font(AppFont.subheadline())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Text("->")
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)

                    Text(L10n.key(item))
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func calloutCard(_ callout: ConnectionGuideCallout) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: callout.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(callout.color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(callout.color.opacity(0.1))
                )

            Text(L10n.key(callout.textKey))
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.4))
        )
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            OpenSourceBadge(style: .dark)

            Text("ISC License")
                .font(AppFont.caption())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

#Preview {
    AboutRemodexView()
}
