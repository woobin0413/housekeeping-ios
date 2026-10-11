import Foundation
import Testing

@testable import HouseKeeping

@MainActor
struct ConnectedInventoryTests {
    @Test func signInLoadsScopedInventoryAndForegroundRestoresDraft() async throws {
        let fixture = ConnectionFixture()
        await fixture.connection.restore()
        #expect(fixture.created.isEmpty)
        await fixture.connection.signIn(email: "first@example.invalid", password: "synthetic")
        let original = try #require(fixture.connection.inventory)
        #expect(original.items.count == 1)
        #expect(original.drafts.begin())
        #expect(original.drafts.edit(.init(name: "Retained across foreground")))
        await fixture.connection.restore()
        let refreshed = try #require(fixture.connection.inventory)
        #expect(refreshed !== original && !original.isActive)
        #expect(refreshed.drafts.draft?.fields.name == "Retained across foreground")
        #expect(fixture.created.count == 2)
    }

    @Test func failedDraftPreservationBlocksAuthenticationTransitionUntilRetry() async throws {
        let fixture = ConnectionFixture()
        await fixture.connection.signIn(email: "first@example.invalid", password: "synthetic")
        let inventory = try #require(fixture.connection.inventory)
        _ = inventory.drafts.begin()
        _ = inventory.drafts.edit(.init(name: "Do not lose me"))
        let disk = try #require(fixture.disks.values.first)
        disk.failSave = true
        let restoreCalls = fixture.auth.restores
        await fixture.connection.restore()
        #expect(fixture.connection.draftTransitionFailed)
        #expect(fixture.auth.restores == restoreCalls)
        #expect(fixture.connection.inventory === inventory)
        #expect(inventory.drafts.draft?.fields.name == "Do not lose me")
        disk.failSave = false
        await fixture.connection.restore()
        #expect(!fixture.connection.draftTransitionFailed)
        #expect(fixture.connection.inventory?.drafts.draft?.fields.name == "Do not lose me")
    }

    @Test func signOutWarnsAndClearsDraftBeforeCredentials() async throws {
        let fixture = ConnectionFixture()
        await fixture.connection.signIn(email: "first@example.invalid", password: "synthetic")
        let inventory = try #require(fixture.connection.inventory)
        _ = inventory.drafts.begin()
        _ = inventory.drafts.edit(.init(name: "Unsaved"))
        #expect(fixture.connection.needsDraftDiscardConfirmation)
        #expect(!(await fixture.connection.signOut()))
        #expect(fixture.auth.signOuts == 0)
        let disk = try #require(fixture.disks.values.first)
        disk.failClear = true
        #expect(!(await fixture.connection.signOut(confirmedDiscard: true)))
        #expect(fixture.auth.signOuts == 0 && fixture.connection.draftTransitionFailed)
        #expect(inventory.drafts.draft?.fields.name == "Unsaved")
        disk.failClear = false
        #expect(await fixture.connection.signOut(confirmedDiscard: true))
        #expect(fixture.auth.signOuts == 1 && disk.value == nil)
        #expect(fixture.connection.inventory == nil && fixture.connection.auth.state == .signedOut)
    }

    @Test func sessionExpiryPreservesPrivateDraftWithoutExposingItToAnotherAccount() async throws {
        let fixture = ConnectionFixture()
        await fixture.connection.signIn(email: "first@example.invalid", password: "synthetic")
        let old = try #require(fixture.connection.inventory)
        _ = old.drafts.begin()
        _ = old.drafts.edit(.init(name: "First person's draft"))
        fixture.auth.account = nil
        await fixture.connection.restore()
        #expect(fixture.connection.auth.state == .signedOut && fixture.connection.inventory == nil)
        #expect(old.items.isEmpty && old.drafts.draft == nil && !old.isActive)
        await fixture.connection.signIn(email: "second@example.invalid", password: "synthetic")
        #expect(fixture.connection.inventory?.drafts.draft == nil)
        #expect(fixture.disks.count == 2)
        #expect(await fixture.connection.signOut())
        await fixture.connection.signIn(email: "first@example.invalid", password: "synthetic")
        #expect(fixture.connection.inventory?.drafts.draft?.fields.name == "First person's draft")
    }

    @Test func noMembershipNeverConstructsInventory() async {
        let fixture = ConnectionFixture()
        fixture.auth.hasHousehold = false
        await fixture.connection.signIn(email: "first@example.invalid", password: "synthetic")
        #expect(fixture.connection.inventory == nil && fixture.created.isEmpty)
        guard case .needsHousehold = fixture.connection.auth.state else {
            Issue.record("Expected the missing-household state")
            return
        }
    }

    @Test func connectedCreateEditDeleteSurvivesStoreReconstructionAndIsShared() async throws {
        let householdID = UUID()
        let accountA = UUID()
        let accountB = UUID()
        let database = PreviewInventoryDatabase()
        let draftDatabase = PreviewDraftDatabase()
        let ownerA = DraftOwner(accountID: accountA, householdID: householdID)
        let ownerB = DraftOwner(accountID: accountB, householdID: householdID)
        let repositoryA = PreviewInventoryRepository(householdID: householdID, database: database)
        let repositoryB = PreviewInventoryRepository(householdID: householdID, database: database)
        let storageA = PreviewDraftStorage(owner: ownerA, database: draftDatabase)
        let first = InventoryStore(repository: repositoryA, draftStorage: storageA, debounce: .zero)
        await first.drafts.restore()
        #expect(first.beginDraft())
        #expect(first.drafts.edit(.init(name: "Shared toaster", description: "Breakfast shelf")))
        let created = try #require(await first.saveDraft())

        let spouse = InventoryStore(
            repository: repositoryB, draftStorage: PreviewDraftStorage(owner: ownerB, database: draftDatabase),
            debounce: .zero)
        await spouse.drafts.restore()
        await spouse.photoDraft?.restore()
        await spouse.refresh()
        #expect(spouse.items.contains(created))
        #expect(spouse.beginDraft(item: created))
        var changed = created.fields
        changed.brand = "House brand"
        #expect(spouse.drafts.edit(changed))
        let edited = try #require(await spouse.saveDraft())
        #expect(edited.version == 2 && edited.brand == "House brand")

        let relaunched = InventoryStore(
            repository: repositoryA, draftStorage: PreviewDraftStorage(owner: ownerA, database: draftDatabase),
            debounce: .zero)
        await relaunched.drafts.restore()
        await relaunched.refresh()
        #expect(relaunched.items.first(where: { $0.id == created.id }) == edited)
        #expect(await relaunched.delete(edited, confirmed: true))
        await spouse.refresh()
        #expect(!spouse.items.contains(where: { $0.id == created.id }))
    }
}

@MainActor
private final class ConnectionFixture {
    let auth = ConnectionAuthentication()
    var disks: [UUID: ConnectionDisk] = [:]
    var created: [InventoryStore] = []
    lazy var connection = AppConnection(auth: auth, recovery: PreviewRecoveryService()) {
        [unowned self] account, home in
        let disk =
            disks[account.id] ?? ConnectionDisk(owner: .init(accountID: account.id, householdID: home.householdId))
        disks[account.id] = disk
        let store = InventoryStore(
            repository: PreviewInventoryRepository(householdID: home.householdId), draftStorage: disk)
        created.append(store)
        return store
    }
}

@MainActor
private final class ConnectionAuthentication: AuthenticationService {
    var account: AccountIdentity?
    var hasHousehold = true
    var restores = 0
    var signOuts = 0
    private var identities: [String: AccountIdentity] = [:]
    private let home = Household(householdId: UUID(), name: "Synthetic home")
    func restore() -> AccountIdentity? {
        restores += 1
        return account
    }
    func signIn(email: String, password: String) -> AccountIdentity {
        let identity = identities[email] ?? AccountIdentity(id: UUID(), email: email)
        identities[email] = identity
        account = identity
        return identity
    }
    func household() throws -> Household {
        guard hasHousehold else { throw AuthenticationFailure.noHousehold }
        return home
    }
    func signOut() -> SignOutResult {
        signOuts += 1
        account = nil
        return .complete
    }
}

@MainActor
private final class ConnectionDisk: DraftStorage {
    let owner: DraftOwner
    var value: TextDraft?
    var failSave = false
    var failClear = false
    init(owner: DraftOwner) { self.owner = owner }
    func load() -> TextDraft? { value }
    func save(_ draft: TextDraft) throws {
        if failSave { throw DraftStorageFailure.unavailable }
        value = draft
    }
    func clear() throws {
        if failClear { throw DraftStorageFailure.unavailable }
        value = nil
    }
}
