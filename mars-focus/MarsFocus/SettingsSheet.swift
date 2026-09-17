import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var screenTime: ScreenTimeManager
    @EnvironmentObject private var coach: CoachStore
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var newException = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    screenTimeSection
                    exceptionsSection
                    coachSection
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { screenTime.refreshStatus() }
    }

    // MARK: - Screen Time

    private var screenTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Screen Time Blocking")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)

            HStack(spacing: 12) {
                Image(systemName: screenTime.isAuthorized ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(screenTime.isAuthorized ? .white : Theme.wine)
                    .frame(width: 34, height: 34)
                    .background(screenTime.isAuthorized ? Theme.wine : Color.white, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Theme.wine, lineWidth: screenTime.isAuthorized ? 0 : 1.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(screenTime.isAuthorized ? "Connected" : "Not connected")
                        .font(.subheadline.weight(.semibold))
                    Text(screenTime.isAuthorized
                         ? "Sessions shield what you've chosen under “Device Apps & Sites” in each blocklist."
                         : "Sessions are tracked in-app only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            if screenTime.isSupported && !screenTime.isAuthorized {
                Button {
                    Task { await screenTime.requestAuthorization() }
                } label: {
                    Text("Enable Screen Time Blocking")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.wine, in: RoundedRectangle(cornerRadius: 14))
                }
            }

            if let error = screenTime.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(screenTime.isSupported
                 ? "Real app blocking uses Apple's Family Controls. To enable it: open the project in Xcode → target → Signing & Capabilities → add “Family Controls”, then run on a real iPhone. It isn't available in the simulator, and Safari history is never accessible to apps."
                 : "OS-level app blocking with Screen Time is available on iPhone and iPad — on the Mac, sessions are tracked in-app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Website exceptions

    private var normalizedNewException: String {
        var site = newException.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://", "www."] where site.hasPrefix(prefix) {
            site = String(site.dropFirst(prefix.count))
        }
        if let slash = site.firstIndex(of: "/") {
            site = String(site[..<slash])
        }
        return site
    }

    private var canAddException: Bool {
        normalizedNewException.contains(".") &&
            !sessionStore.websiteExceptions.contains(normalizedNewException)
    }

    private var exceptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Website Exceptions")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            Text("Sites that stay reachable during “Block everything” sessions — your docs, mail, or anything work needs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("example.com", text: $newException)
                    .font(.subheadline.weight(.semibold))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit(addException)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                Button(action: addException) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canAddException ? Theme.wine : Theme.wine.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!canAddException)
                .accessibilityLabel("Add exception")
            }
            ForEach(sessionStore.websiteExceptions, id: \.self) { site in
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.wine)
                        .frame(width: 34, height: 34)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.wine, lineWidth: 1.5))
                    Text(site)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        sessionStore.setWebsiteExceptions(
                            sessionStore.websiteExceptions.filter { $0 != site })
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(site)")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func addException() {
        guard canAddException else { return }
        sessionStore.setWebsiteExceptions(sessionStore.websiteExceptions + [normalizedNewException])
        newException = ""
    }

    // MARK: - AI Coach

    private var coachSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Coach")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)

            Picker("Provider", selection: $coach.provider) {
                ForEach(CoachProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            SecureField("API key", text: $coach.apiKey)
                .font(.subheadline.weight(.semibold))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            Text(coach.provider.keyFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The key is stored in this device's Keychain and sent only to the provider you picked, along with your focus stats when you message the coach.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = coach.keyStorageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !coach.messages.isEmpty {
                Button {
                    coach.clearConversation()
                } label: {
                    Text("Clear Conversation")
                        .font(.headline)
                        .foregroundStyle(Theme.wine)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(coach.isLoading)
            }
        }
    }
}
