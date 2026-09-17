import SwiftUI

/// Sign in to (or create) a sync account so data follows the user across
/// iPhone, iPad, Mac, and the web app.
struct AccountSheet: View {
    @EnvironmentObject private var store: EntryStore
    @Environment(\.dismiss) private var dismiss

    @State private var serverText = "http://localhost:8473"
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let account = store.account {
                    signedInContent(account)
                } else {
                    signedOutContent
                }
            }
            .navigationTitle("Account")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .mediumOrLargeSheet()
        .onAppear {
            if let account = store.account {
                serverText = account.server.absoluteString
                username = account.username
            }
        }
    }

    @ViewBuilder
    private func signedInContent(_ account: SyncAccount) -> some View {
        Section {
            LabeledContent("Account", value: account.username)
            LabeledContent("Server", value: account.server.absoluteString)
            LabeledContent("Last synced", value: store.lastSyncedAt.map {
                $0.formatted(.relative(presentation: .named))
            } ?? "never")
        } header: {
            Text("Signed in")
        } footer: {
            statusFooter
        }
        Section {
            Button {
                Task {
                    busy = true
                    await store.syncNow()
                    busy = false
                }
            } label: {
                HStack {
                    Text("Sync Now")
                    if busy || store.syncStatus == .syncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(busy)
            Button("Sign Out", role: .destructive) {
                Task {
                    await store.signOut()
                }
            }
        } footer: {
            Text("Signing out keeps this device's data; it just stops syncing.")
        }
    }

    @ViewBuilder
    private var signedOutContent: some View {
        Section {
            TextField("Server", text: $serverText)
                .textContentTypeNone()
            TextField("Username", text: $username)
                .textContentTypeNone()
            SecureField("Password (8+ characters)", text: $password)
        } header: {
            Text("Sync server")
        } footer: {
            Text("Your own Mars Momentum server — see MarsMomentumServer in the project folder. The same account works in the web app.")
        }
        Section {
            Button {
                submit(creating: false)
            } label: {
                labelWithSpinner("Sign In")
            }
            .disabled(busy || !formValid)
            Button {
                submit(creating: true)
            } label: {
                labelWithSpinner("Create Account")
            }
            .disabled(busy || !formValid)
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if case .error(let message) = store.syncStatus {
            Text(message).foregroundStyle(.red)
        }
    }

    private func labelWithSpinner(_ title: String) -> some View {
        HStack {
            Text(title)
            if busy {
                Spacer()
                ProgressView()
            }
        }
    }

    private var formValid: Bool {
        !serverText.isEmpty && !username.isEmpty && password.count >= 8
    }

    private func submit(creating: Bool) {
        busy = true
        errorMessage = nil
        Task {
            let error = await store.signIn(
                serverText: serverText, username: username, password: password, creating: creating)
            busy = false
            if let error {
                errorMessage = error
            } else {
                password = ""
            }
        }
    }
}

private extension View {
    /// Disables autocapitalization/correction for URL and username fields
    /// where the iOS keyboard would otherwise mangle input.
    @ViewBuilder
    func textContentTypeNone() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
