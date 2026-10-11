import Foundation
import Testing

@testable import HouseKeeping

@MainActor
struct AppConnectionTests {
    @Test func previewAccountsShareAStableHousehold() async throws {
        let service = PreviewAuthenticationService()
        _ = try await service.signIn(email: "first@example.invalid", password: "demo-password")
        let firstHousehold = try await service.household()
        _ = try await service.signOut()
        _ = try await service.signIn(email: "second@example.invalid", password: "demo-password")
        let secondHousehold = try await service.household()
        #expect(firstHousehold == secondHousehold)
    }

    @Test func callbackWaitsForRequest() async throws {
        let service = SuspendedRecoveryService()
        let connection = AppConnection(auth: PreviewAuthenticationService(), recovery: service)
        await connection.restore()
        connection.recovery.begin()
        service.suspendRequest = true
        let request = Task { await connection.recovery.request(email: "person@example.invalid") }
        while service.continuation == nil { await Task.yield() }
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic"))
        let callback = Task { await connection.openRecovery(url) }
        await Task.yield()
        #expect(service.accepted == 0)
        service.continuation?.resume()
        await request.value
        await callback.value
        #expect(service.accepted == 1)
        #expect(connection.recovery.state == .passwordEntry(email: "person@example.invalid"))
    }

    @Test func callbackWaitsForInitialRestoration() async throws {
        let service = SuspendedRecoveryService()
        service.status = .awaitingEmail
        service.suspendRestore = true
        let connection = AppConnection(auth: PreviewAuthenticationService(), recovery: service)
        let restoration = Task { await connection.restore() }
        while service.continuation == nil { await Task.yield() }
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic"))
        let callback = Task { await connection.openRecovery(url) }
        await Task.yield()
        #expect(service.accepted == 0)
        service.continuation?.resume()
        await restoration.value
        await callback.value
        #expect(service.accepted == 1)
    }

    @Test func callbackAfterCancellationIsExplicitlyRejectedNotDropped() async throws {
        let service = SuspendedRecoveryService()
        service.status = .awaitingEmail
        let connection = AppConnection(auth: PreviewAuthenticationService(), recovery: service)
        await connection.restore()
        service.suspendCleanup = true
        let cleanup = Task { await connection.recovery.close() }
        while service.continuation == nil { await Task.yield() }
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic"))
        let callback = Task { await connection.openRecovery(url) }
        await Task.yield()
        service.continuation?.resume()
        await cleanup.value
        await callback.value
        #expect(service.accepted == 1)
        #expect(connection.recovery.failure == .invalidLink)
    }

    @Test func recoveryCallbackCannotSwitchAnActiveNormalAccount() async throws {
        let service = SuspendedRecoveryService()
        let connection = AppConnection(auth: PreviewAuthenticationService(), recovery: service)
        await connection.restore()
        await connection.auth.signIn(email: "spouse@example.invalid", password: "demo-password")
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic"))
        await connection.openRecovery(url)
        #expect(connection.callbackRequiresSignOut)
        #expect(service.accepted == 0)
        #expect(connection.recovery.state == .inactive)
    }

    @Test func passwordChangeCleanupFailureDoesNotRepeatPasswordUpdate() async throws {
        let service = SuspendedRecoveryService()
        service.status = .passwordEntry(email: "person@example.invalid")
        let recovery = PasswordRecovery(service: service)
        await recovery.restore()
        service.failCleanup = true
        await recovery.save(password: "synthetic-password", confirmation: "synthetic-password")
        #expect(recovery.state == .passwordChanged)
        #expect(recovery.needsCleanup)
        service.failCleanup = false
        await recovery.close()
        #expect(recovery.state == .inactive)
        #expect(service.passwordUpdates == 1)
    }
}

@MainActor
private final class SuspendedRecoveryService: PasswordRecoveryService {
    var status: RecoveryStatus?
    var suspendRequest = false
    var suspendRestore = false
    var suspendCleanup = false
    var failCleanup = false
    var continuation: CheckedContinuation<Void, Never>?
    var accepted = 0
    var passwordUpdates = 0
    func restoreRecovery() async throws -> RecoveryStatus? {
        if suspendRestore { await withCheckedContinuation { continuation = $0 } }
        return status
    }
    func requestRecovery(email: String) async throws {
        if suspendRequest { await withCheckedContinuation { continuation = $0 } }
        status = .awaitingEmail
    }
    func acceptRecovery(url: URL) async throws -> String {
        accepted += 1
        guard status != nil else { throw RecoveryFailure.invalidLink }
        return "person@example.invalid"
    }
    func changePassword(_ password: String) async throws { passwordUpdates += 1 }
    func clearRecovery() async throws -> SignOutResult {
        if suspendCleanup { await withCheckedContinuation { continuation = $0 } }
        if failCleanup { throw RecoveryFailure.protectedStorage }
        status = nil
        return .complete
    }
}
