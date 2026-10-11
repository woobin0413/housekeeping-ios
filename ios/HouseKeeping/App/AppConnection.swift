import Foundation
import Observation

@MainActor @Observable
final class AppConnection {
    let auth: AuthSession
    let recovery: PasswordRecovery
    private(set) var isRestoring = true
    private(set) var callbackRequiresSignOut = false
    private(set) var inventory: InventoryStore?
    private(set) var draftTransitionFailed = false
    private let makeInventory: (@MainActor (AccountIdentity, Household) -> InventoryStore)?
    @ObservationIgnored private var isTransitioning = false
    @ObservationIgnored private var restoration: Task<Void, Never>?

    init(
        auth: any AuthenticationService, recovery: any PasswordRecoveryService,
        makeInventory: (@MainActor (AccountIdentity, Household) -> InventoryStore)? = nil
    ) {
        self.auth = AuthSession(service: auth)
        self.recovery = PasswordRecovery(service: recovery)
        self.makeInventory = makeInventory
    }

    func restore() async {
        if let restoration {
            await restoration.value
            return
        }
        guard !isTransitioning, !auth.isBusy else { return }
        isTransitioning = true
        isRestoring = true
        let task = Task {
            defer {
                isRestoring = false
                isTransitioning = false
            }
            guard await retireInventory() else { return }
            await recovery.restore()
            await auth.restore()
            await loadInventory()
        }
        restoration = task
        await task.value
        restoration = nil
    }

    func signIn(email: String, password: String) async {
        guard !isTransitioning, !auth.isBusy, auth.state == .signedOut else { return }
        isTransitioning = true
        isRestoring = true
        defer {
            isTransitioning = false
            isRestoring = false
        }
        guard await retireInventory() else { return }
        await auth.signIn(email: email, password: password)
        await loadInventory()
    }

    var needsDraftDiscardConfirmation: Bool {
        guard let drafts = inventory?.drafts else { return false }
        return !drafts.hasLoaded || drafts.draft != nil || drafts.storageFailure != nil
            || inventory?.photoDraft?.needsDiscardConfirmation == true
    }

    @discardableResult
    func signOut(confirmedDiscard: Bool = false) async -> Bool {
        guard !isTransitioning, !auth.isBusy,
            confirmedDiscard || !needsDraftDiscardConfirmation
        else { return false }
        isTransitioning = true
        isRestoring = true
        defer {
            isTransitioning = false
            isRestoring = false
        }
        if let inventory, !(await inventory.deactivate(confirmedDiscard: confirmedDiscard)) {
            draftTransitionFailed = true
            return false
        }
        inventory = nil
        draftTransitionFailed = false
        await auth.signOut()
        return auth.state == .signedOut
    }

    private func retireInventory() async -> Bool {
        if let inventory, !(await inventory.retire()) {
            draftTransitionFailed = true
            return false
        }
        inventory = nil
        draftTransitionFailed = false
        return true
    }

    private func loadInventory() async {
        guard case .ready(let account, let household) = auth.state,
            let makeInventory
        else { return }
        let store = makeInventory(account, household)
        inventory = store
        await store.drafts.restore()
        await store.photoDraft?.restore()
        await store.refresh()
    }

    func openRecovery(_ url: URL) async {
        if let restoration { await restoration.value }
        guard !isTransitioning, !auth.isBusy, auth.state == .signedOut else {
            callbackRequiresSignOut = true
            return
        }
        callbackRequiresSignOut = false
        await recovery.accept(url: url)
    }
}

#if DEBUG
    /// Offline-only dependencies for previews and deterministic UI tests. Never used by Release.
    @MainActor
    final class PreviewAuthenticationService: AuthenticationService {
        private var account: AccountIdentity?
        private let household = Household(householdId: UUID(), name: "Our home")

        func restore() async throws -> AccountIdentity? { account }
        func signIn(email: String, password: String) async throws -> AccountIdentity {
            guard password == "demo-password" else { throw AuthenticationFailure.invalidCredentials }
            let identity = AccountIdentity(id: UUID(), email: email)
            account = identity
            return identity
        }
        func household() async throws -> Household {
            if account?.email == "unassigned@example.invalid" { throw AuthenticationFailure.noHousehold }
            return household
        }
        func signOut() async throws -> SignOutResult {
            account = nil
            return .complete
        }
    }

    @MainActor
    final class PreviewRecoveryService: PasswordRecoveryService {
        var status: RecoveryStatus?
        init(status: RecoveryStatus? = nil) { self.status = status }
        func restoreRecovery() async throws -> RecoveryStatus? { status }
        func requestRecovery(email: String) async throws { status = .awaitingEmail }
        func acceptRecovery(url: URL) async throws -> String {
            _ = try AuthCallbackHandler.recoveryCode(from: url)
            guard status != nil else { throw RecoveryFailure.invalidLink }
            status = .passwordEntry(email: "person@example.invalid")
            return "person@example.invalid"
        }
        func changePassword(_ password: String) async throws {
            guard password.count >= 12, password.utf8.count <= 72 else { throw RecoveryFailure.invalidPassword }
        }
        func clearRecovery() async throws -> SignOutResult {
            status = nil
            return .complete
        }
    }
#endif
