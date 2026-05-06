// FILE: GPTVoiceSetupSheet.swift
// Purpose: Shows a compact info sheet that explains how Remodex voice uses bridge-managed ChatGPT transcription.
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
                        Text("Voice mode uses ChatGPT transcription")
                            .font(AppFont.subheadline(weight: .semibold))
                        Text("Remodex records on the iPhone, asks your paired Mac bridge for ChatGPT auth, and uploads the clip for transcription.")
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
                        title: "The phone asks your paired Mac bridge for auth",
                        detail: "Remodex uses the ChatGPT session already available through your local Mac bridge."
                    )
                    infoStep(
                        number: "3",
                        title: "ChatGPT transcribes the clip",
                        detail: "The recorded WAV is sent with the bridge-resolved ChatGPT token after you release the mic."
                    )
                    infoStep(
                        number: "4",
                        title: "The text comes back to Remodex",
                        detail: "The final transcript returns to the app and lands directly in your message composer."
                    )
                }

                Text("In short: iPhone records locally, the paired Mac bridge supplies ChatGPT auth, and the final transcript comes back to the draft.")
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
