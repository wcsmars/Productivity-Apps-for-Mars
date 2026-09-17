import SwiftUI

struct CoachTabView: View {
    @EnvironmentObject private var coach: CoachStore
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var draft = ""
    @State private var showingSettings = false
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "How am I doing this week?",
        "Help me plan tomorrow",
        "Why do I quit sessions early?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            if coach.messages.isEmpty {
                                emptyState
                            }
                            ForEach(coach.messages) { message in
                                bubble(for: message)
                                    .id(message.id)
                            }
                            if coach.isLoading {
                                typingIndicator
                            }
                            if let error = coach.errorText {
                                errorCard(error)
                            }
                            // Anchor below the indicator/error so they scroll
                            // into view too, not just the last message.
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .onChange(of: coach.messages) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: coach.isLoading) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: coach.errorText) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                inputBar
            }
            .background(Color.white)
            .navigationTitle("Coach")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Theme.wine)
                    }
                    .accessibilityLabel("Coach settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet()
            }
        }
    }

    // MARK: - Messages

    private func bubble(for message: CoachMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(message.role == .user ? .white : Color.primary)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    message.role == .user ? Theme.wine : Theme.blush,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            if message.role == .coach { Spacer(minLength: 40) }
        }
    }

    private var typingIndicator: some View {
        HStack {
            ProgressView()
                .tint(Theme.wine)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            Spacer()
        }
    }

    private func errorCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.wine)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.wine)
                .padding(.top, 24)
            Text("Your focus coach")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.wineDeep)
            Text("Ask anything about your focus habits — the coach sees your streaks, schedules, and session history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if coach.isConfigured {
                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            send(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.wineDeep)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity)
                                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            } else {
                Button {
                    showingSettings = true
                } label: {
                    Text("Add an API key in Settings")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.wine, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.top, 8)
                Text("The coach is optional. Add your own Gemini or Claude API key in Settings; provider quotas and billing apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask your coach…", text: $draft, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Theme.wine : Theme.wine.opacity(0.35))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.white)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coach.isLoading
    }

    private func send(_ text: String) {
        let message = text
        draft = ""
        Task {
            // Undelivered text comes back so it isn't silently lost.
            if let restore = await coach.send(message, context: sessionStore.coachContext()),
               draft.isEmpty {
                draft = restore
            }
        }
    }
}
