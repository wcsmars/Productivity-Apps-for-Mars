import Foundation
import Combine
#if !targetEnvironment(macCatalyst)
import FamilyControls
import ManagedSettings
#endif

/// Bridges to Apple's Screen Time (Family Controls) framework so focus sessions
/// can shield real apps and websites at the OS level.
///
/// Fully optional: the entitlement (com.apple.developer.family-controls) must be
/// added in Xcode's Signing & Capabilities and the app run on a real device.
/// Without it — and on the simulator — authorization fails gracefully and
/// sessions stay tracked in-app only. Family Controls doesn't exist on the Mac
/// at all, so the Catalyst build compiles this class down to inert stubs.
@MainActor
final class ScreenTimeManager: ObservableObject, SessionShielding {
    @Published private(set) var isAuthorized = false
    @Published private(set) var lastError: String?

    /// Whether this platform can do OS-level shielding at all.
    #if targetEnvironment(macCatalyst)
    let isSupported = false
    #else
    let isSupported = true
    #endif

    /// Fires when authorization flips (e.g. granted mid-session or resolved
    /// late after a cold launch), so the session store can re-apply shields.
    var onAuthorizationChange: (() -> Void)?

    #if !targetEnvironment(macCatalyst)
    private let store = ManagedSettingsStore()
    private var statusCancellable: AnyCancellable?

    init() {
        refreshStatus()
        // AuthorizationCenter can still report .notDetermined for a moment
        // after launch — track it instead of trusting a one-shot snapshot.
        statusCancellable = AuthorizationCenter.shared.$authorizationStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let wasAuthorized = self.isAuthorized
                    self.refreshStatus()
                    if self.isAuthorized != wasAuthorized {
                        self.onAuthorizationChange?()
                    }
                }
            }
    }

    func refreshStatus() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
    }

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshStatus()
    }

    /// Shields every device app/category/website selected in the given
    /// blocklists, and filters every typed or keyword-expanded domain
    /// (the web-content filter accepts plain domain strings, so those work
    /// without the Family Activity picker). With `blockAllWebsites`, the whole
    /// web is filtered except the given exception domains. No-op without authorization.
    func applyShields(for blocklists: [Blocklist],
                      blockAllWebsites: Bool = false,
                      websiteExceptions: [String] = []) {
        guard isAuthorized else { return }
        var applications: Set<ApplicationToken> = []
        var categories: Set<ActivityCategoryToken> = []
        var webDomains: Set<WebDomainToken> = []
        var filteredDomains: Set<WebDomain> = []
        for list in blocklists {
            for domain in list.blockedDomains {
                filteredDomains.insert(WebDomain(domain: domain))
            }
            guard let selection = list.screenTimeSelection else { continue }
            applications.formUnion(selection.applicationTokens)
            categories.formUnion(selection.categoryTokens)
            webDomains.formUnion(selection.webDomainTokens)
        }
        store.shield.applications = applications.isEmpty ? nil : applications
        store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
        store.shield.webDomains = webDomains.isEmpty ? nil : webDomains
        if blockAllWebsites {
            store.webContent.blockedByFilter =
                .all(except: Set(websiteExceptions.map { WebDomain(domain: $0) }))
        } else {
            store.webContent.blockedByFilter = filteredDomains.isEmpty ? nil : .specific(filteredDomains)
        }
    }

    func clearShields() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.webContent.blockedByFilter = nil
    }
    #else
    init() {}
    func refreshStatus() {}
    func requestAuthorization() async {}
    func applyShields(for blocklists: [Blocklist],
                      blockAllWebsites: Bool = false,
                      websiteExceptions: [String] = []) {}
    func clearShields() {}
    #endif
}
