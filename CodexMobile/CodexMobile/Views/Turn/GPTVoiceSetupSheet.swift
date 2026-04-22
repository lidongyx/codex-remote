// FILE: GPTVoiceSetupSheet.swift
// Purpose: Shows a compact info sheet that explains how Remodex voice uses bridge-managed Bailian realtime dictation.
// Layer: View
// Exports: GPTVoiceSetupSheet
// Depends on: SwiftUI, AppFont

import SwiftUI

struct GPTVoiceSetupSheet: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice mode uses Bailian realtime dictation")
                            .font(AppFont.subheadline(weight: .semibold))
                        Text("Remodex asks the paired Mac bridge for your local Bailian realtime setup, then keeps the dictation flow on that realtime path only.")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    infoStep(
                        number: "1",
                        title: "You speak on the iPhone",
                        detail: "Remodex records microphone audio locally on the phone when you hold to talk."
                    )
                    infoStep(
                        number: "2",
                        title: "The phone asks your paired Mac bridge for setup",
                        detail: "Remodex reads the Bailian realtime endpoint, model, and local auth that you configured on the Mac."
                    )
                    infoStep(
                        number: "3",
                        title: "Bailian transcribes while you speak",
                        detail: "The iPhone streams PCM audio into the Bailian realtime session so the draft updates live while you speak."
                    )
                    infoStep(
                        number: "4",
                        title: "The text comes back to Remodex",
                        detail: "Partial and final transcript text returns to the app and lands directly in your message composer."
                    )
                }

                Text("In short: iPhone records locally, the paired Mac bridge supplies Bailian realtime setup, and transcript text streams back into the draft live.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(20)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .navigationTitle("How Voice Mode Works")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // Keeps the voice flow easy to scan in a compact informational sheet.
    private func infoStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
