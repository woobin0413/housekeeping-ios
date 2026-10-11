import Foundation
import Testing

@testable import HouseKeeping

@MainActor
struct AuthSessionTests {
    @Test func signInLoadsSharedHouseholdThenSignOutClearsIdentity() async {
        let service = FakeAuthenticationService()
        let model = AuthSession(service: service)
        await model.signIn(email: " person@example.invalid ", password: "synthetic")
        #expect(model.state == .ready(service.identity, service.home))
        #expect(service.receivedEmail == "person@example.invalid")
        await model.signOut()
        #expect(model.state == .signedOut)
        #expect(model.failure == nil)
    }

    @Test func restoreWithNoSessionIsSignedOut() async {
        let service = FakeAuthenticationService()
        service.restoredIdentity = nil
        let model = AuthSession(service: service)
        await model.restore()
        #expect(model.state == .signedOut)
    }

    @Test func restoreRevalidatesRevokedMembership() async {
        let service = FakeAuthenticationService()
        let model = AuthSession(service: service)
        await model.restore()
        #expect(model.state == .ready(service.identity, service.home))
        service.householdFailure = .noHousehold
        await model.restore()
        #expect(model.state == .needsHousehold(service.identity))
    }

    @Test(arguments: [AuthenticationFailure.invalidCredentials, .emailUnverified, .sessionExpired])
    func failedAuthenticationHasNoAccount(failure: AuthenticationFailure) async {
        let service = FakeAuthenticationService()
        service.authFailure = failure
        let model = AuthSession(service: service)
        await model.signIn(email: "person@example.invalid", password: "synthetic")
        #expect(model.state == .signedOut)
        #expect(model.failure == failure)
        #expect(!model.isBusy)
    }

    @Test func offlineSignOutDistinguishesLocalDeletionFromServerRevocation() async {
        let service = FakeAuthenticationService()
        service.signOutResult = .localOnly
        let model = AuthSession(service: service)
        await model.restore()
        await model.signOut()
        #expect(model.state == .signedOut)
        #expect(model.signOutWasLocalOnly)
    }

    @Test func failedCredentialRemovalBlocksInsteadOfClaimingSignOut() async {
        let service = FakeAuthenticationService()
        let model = AuthSession(service: service)
        await model.restore()
        service.signOutFailure = .protectedStorage
        await model.signOut()
        #expect(model.state == .blocked(.protectedStorage))
    }

    @Test func concurrentOperationsCannotSwitchAccounts() async {
        let service = FakeAuthenticationService()
        service.suspendRestore = true
        let model = AuthSession(service: service)
        let restoration = Task { await model.restore() }
        while service.restoreContinuation == nil { await Task.yield() }
        #expect(model.state == .checking)
        await model.signIn(email: "other@example.invalid", password: "synthetic")
        #expect(service.receivedEmail == nil)
        service.restoreContinuation?.resume(returning: service.identity)
        await restoration.value
        #expect(model.state == .ready(service.identity, service.home))
    }
}

@MainActor
private final class FakeAuthenticationService: AuthenticationService {
    let identity = AccountIdentity(id: UUID(), email: "person@example.invalid")
    let home = Household(householdId: UUID(), name: "Our home")
    var restoredIdentity: AccountIdentity?
    var receivedEmail: String?
    var authFailure: AuthenticationFailure?
    var householdFailure: AuthenticationFailure?
    var signOutFailure: AuthenticationFailure?
    var signOutResult = SignOutResult.complete
    var suspendRestore = false
    var restoreContinuation: CheckedContinuation<AccountIdentity?, Never>?

    init() { restoredIdentity = identity }
    func restore() async throws -> AccountIdentity? {
        if let authFailure { throw authFailure }
        if suspendRestore { return await withCheckedContinuation { restoreContinuation = $0 } }
        return restoredIdentity
    }
    func signIn(email: String, password: String) async throws -> AccountIdentity {
        receivedEmail = email
        if let authFailure { throw authFailure }
        return identity
    }
    func household() async throws -> Household {
        if let householdFailure { throw householdFailure }
        return home
    }
    func signOut() async throws -> SignOutResult {
        if let signOutFailure { throw signOutFailure }
        return signOutResult
    }
}
