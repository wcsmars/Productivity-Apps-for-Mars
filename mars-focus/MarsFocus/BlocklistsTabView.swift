import SwiftUI
#if !targetEnvironment(macCatalyst)
import FamilyControls
#endif

struct BlocklistsTabView: View {
    @EnvironmentObject private var blocklistStore: BlocklistStore
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var editingList: Blocklist?
    @State private var creatingList = false
    @State private var showingLockedAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if blocklistStore.blocklists.isEmpty {
                        Text("No blocklists yet — tap + to create your first one.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(blocklistStore.blocklists) { list in
                            BlocklistRow(
                                list: list,
                                isLockedNow: sessionStore.lockedBlocklistIDs.contains(list.id),
                                onTap: {
                                    if sessionStore.lockedBlocklistIDs.contains(list.id) {
                                        showingLockedAlert = true
                                    } else {
                                        editingList = list
                                    }
                                },
                                onDelete: {
                                    blocklistStore.delete(list)
                                    // Keep OS shields in sync if the deleted
                                    // list was part of the running session.
                                    sessionStore.refreshShields()
                                }
                            )
                        }
                        Text("Blocklists define what you're avoiding while a focus session runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Blocklists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creatingList = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.wine)
                    }
                    .accessibilityLabel("New blocklist")
                }
            }
            .sheet(item: $editingList) { list in
                BlocklistEditorSheet(existing: list)
            }
            .sheet(isPresented: $creatingList) {
                BlocklistEditorSheet(existing: nil)
            }
            .alert("This blocklist is locked", isPresented: $showingLockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("It's part of a locked focus session and can be edited again once the session ends.")
            }
        }
    }
}

private struct BlocklistRow: View {
    let list: Blocklist
    let isLockedNow: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Theme.wine, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(list.itemSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isLockedNow {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.wine)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLockedNow {
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(list.name)")
                .confirmationDialog(
                    "Delete \"\(list.name)\"?",
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive, action: onDelete)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Editor

struct BlocklistEditorSheet: View {
    let existing: Blocklist?

    @EnvironmentObject private var blocklistStore: BlocklistStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var screenTime: ScreenTimeManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selectedApps: Set<String>
    @State private var websites: [String]
    @State private var newWebsite = ""
    @State private var keywords: [String]
    @State private var newKeyword = ""
    #if !targetEnvironment(macCatalyst)
    @State private var activitySelection: FamilyActivitySelection
    @State private var showingActivityPicker = false
    #endif
    @State private var didSave = false
    @State private var showingLockedAlert = false

    init(existing: Blocklist?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _selectedApps = State(initialValue: Set(existing?.appIDs ?? []))
        _websites = State(initialValue: existing?.websites ?? [])
        _keywords = State(initialValue: existing?.keywords ?? [])
        #if !targetEnvironment(macCatalyst)
        _activitySelection = State(initialValue: existing?.screenTimeSelection ?? FamilyActivitySelection())
        #endif
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    appsSection
                    websitesSection
                    keywordsSection
                    screenTimeSection
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle(existing == nil ? "New Blocklist" : "Edit Blocklist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveAndDismiss)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.large])
        .alert("This blocklist is locked", isPresented: $showingLockedAlert) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("A locked focus session started using it while you were editing. Your changes weren't saved.")
        }
    }

    private func saveAndDismiss() {
        guard !didSave, canSave else { return }
        // Re-check at commit time: a locked session may have started using this
        // list while the editor was open, and the tap-time guard can't see that.
        if let existing, sessionStore.lockedBlocklistIDs.contains(existing.id) {
            showingLockedAlert = true
            return
        }
        didSave = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let orderedApps = AppCatalog.all.map(\.id).filter(selectedApps.contains)
        if let existing {
            var updated = existing
            updated.name = trimmed
            updated.appIDs = orderedApps
            updated.websites = websites
            updated.keywords = keywords
            #if !targetEnvironment(macCatalyst)
            if activitySelectionIsEmpty, existing.screenTimeSelectionData != nil,
               existing.screenTimeSelection == nil {
                // The stored selection couldn't be decoded (e.g. after an OS
                // change), so the picker opened empty — keep the original
                // bytes instead of silently wiping the user's selection.
            } else {
                updated.screenTimeSelection = activitySelectionIsEmpty ? nil : activitySelection
            }
            #endif
            blocklistStore.update(updated)
        } else {
            var created = Blocklist(name: trimmed, appIDs: orderedApps, websites: websites, keywords: keywords)
            #if !targetEnvironment(macCatalyst)
            created.screenTimeSelection = activitySelectionIsEmpty ? nil : activitySelection
            #endif
            blocklistStore.add(created)
        }
        // Keep OS shields in sync if this list is part of the running session.
        sessionStore.refreshShields()
        dismiss()
    }

    #if !targetEnvironment(macCatalyst)
    private var activitySelectionIsEmpty: Bool {
        activitySelection.applicationTokens.isEmpty
            && activitySelection.categoryTokens.isEmpty
            && activitySelection.webDomainTokens.isEmpty
    }
    #endif

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            TextField("e.g. Social Media", text: $name)
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(AppCatalog.all) { app in
                    let isSelected = selectedApps.contains(app.id)
                    Button {
                        if isSelected {
                            selectedApps.remove(app.id)
                        } else {
                            selectedApps.insert(app.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: app.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 20)
                            Text(app.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                            }
                        }
                        .foregroundStyle(isSelected ? .white : Theme.wineDeep)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                        .background(
                            isSelected ? Theme.wine : Theme.blush,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var websitesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Websites")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            HStack(spacing: 8) {
                TextField("example.com", text: $newWebsite)
                    .font(.subheadline.weight(.semibold))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit(addWebsite)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                Button(action: addWebsite) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canAddWebsite ? Theme.wine : Theme.wine.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!canAddWebsite)
                .accessibilityLabel("Add website")
            }
            ForEach(websites, id: \.self) { site in
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.wine)
                        .frame(width: 34, height: 34)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.wine, lineWidth: 1.5))
                    Text(site)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        websites.removeAll { $0 == site }
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

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keywords")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            Text("Block whole categories at once — a keyword expands to every matching site we know.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Quick-add chips for the built-in categories.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(KeywordCatalog.suggestions, id: \.self) { suggestion in
                        let isOn = keywords.contains(suggestion)
                        Button {
                            if isOn {
                                keywords.removeAll { $0 == suggestion }
                            } else {
                                keywords.append(suggestion)
                            }
                        } label: {
                            Text(suggestion)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(isOn ? Theme.wine : Theme.blush, in: Capsule())
                                .foregroundStyle(isOn ? .white : Theme.wineDeep)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("e.g. anime", text: $newKeyword)
                    .font(.subheadline.weight(.semibold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(addKeyword)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                Button(action: addKeyword) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canAddKeyword ? Theme.wine : Theme.wine.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!canAddKeyword)
                .accessibilityLabel("Add keyword")
            }
            ForEach(keywords, id: \.self) { keyword in
                let matches = KeywordCatalog.domains(for: keyword).count
                HStack(spacing: 12) {
                    Image(systemName: "textformat.abc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.wine)
                        .frame(width: 34, height: 34)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.wine, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(keyword)
                            .font(.subheadline.weight(.semibold))
                        Text(matches > 0 ? "Blocks \(matches) site\(matches == 1 ? "" : "s")"
                                         : "No known sites match yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        keywords.removeAll { $0 == keyword }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(keyword)")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var normalizedNewKeyword: String {
        newKeyword.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private var canAddKeyword: Bool {
        !normalizedNewKeyword.isEmpty && !keywords.contains(normalizedNewKeyword)
    }

    private func addKeyword() {
        guard canAddKeyword else { return }
        keywords.append(normalizedNewKeyword)
        newKeyword = ""
    }

    @ViewBuilder
    private var screenTimeSection: some View {
        #if targetEnvironment(macCatalyst)
        VStack(alignment: .leading, spacing: 10) {
            Text("Device Apps & Sites")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            Text("OS-level app blocking with Screen Time is available on iPhone and iPad. Selections made there are kept and keep working.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        #else
        VStack(alignment: .leading, spacing: 10) {
            Text("Device Apps & Sites")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            if screenTime.isAuthorized {
                Button {
                    showingActivityPicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Theme.wine, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose with Screen Time")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(activitySelectionIsEmpty
                                 ? "Nothing selected yet"
                                 : "\(activitySelection.applicationTokens.count + activitySelection.categoryTokens.count + activitySelection.webDomainTokens.count) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .familyActivityPicker(isPresented: $showingActivityPicker, selection: $activitySelection)
                Text("These are shielded at the OS level while a session runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect Screen Time in Settings (Focus tab → gear) to block real apps and websites on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #endif
    }

    private var normalizedNewWebsite: String {
        var site = newWebsite.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://", "www."] where site.hasPrefix(prefix) {
            site = String(site.dropFirst(prefix.count))
        }
        if let slash = site.firstIndex(of: "/") {
            site = String(site[..<slash])
        }
        return site
    }

    private var canAddWebsite: Bool {
        let site = normalizedNewWebsite
        return site.contains(".") && !websites.contains(site)
    }

    private func addWebsite() {
        guard canAddWebsite else { return }
        websites.append(normalizedNewWebsite)
        newWebsite = ""
    }
}
