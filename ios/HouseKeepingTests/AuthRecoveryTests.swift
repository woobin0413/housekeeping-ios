import Foundation
import Supabase
import Testing

@testable import HouseKeeping

struct AuthCallbackTests {
    @Test func acceptsOnlyExpectedCodeCallback() throws {
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic-code"))
        #expect(try AuthCallbackHandler.recoveryCode(from: url) == "synthetic-code")
    }

    @Test(arguments: [
        "https://auth/recovery?code=x", "housekeeping://foreign/recovery?code=x",
        "housekeeping://auth/other?code=x", "housekeeping://auth/recovery?code=",
        "housekeeping://auth/recovery?code=a&code=b", "housekeeping://auth/recovery?code=a&next=evil",
        "housekeeping://auth/recovery#access_token=x", "housekeeping://user@auth/recovery?code=a",
        "housekeeping://auth:12/recovery?code=a", "housekeeping://auth/recovery?code=%0Asecret",
    ])
    func rejectsUnexpectedCallback(value: String) throws {
        let url = try #require(URL(string: value))
        #expect(throws: RecoveryFailure.invalidLink) { try AuthCallbackHandler.recoveryCode(from: url) }
    }

    @Test func expiresInOneHourAndRejectsClockRollback() {
        let date = Date()
        let request = PendingRecovery(email: "test@example.invalid", requestedAt: date)
        #expect(request.isValid(at: date.addingTimeInterval(3599)))
        #expect(!request.isValid(at: date.addingTimeInterval(3600)))
        #expect(!request.isValid(at: date.addingTimeInterval(-1)))
    }
}

extension SupabaseAuthServiceTests {
    @Test func recoveryRequestAndPasswordChangeStayInSeparateSession() async throws {
        let storage = MemoryAuthStorage()
        let recovered = fixture()
        let sessionData = try AuthClient.Configuration.jsonEncoder.encode(recovered)
        let userData = try AuthClient.Configuration.jsonEncoder.encode(recovered.user)
        OfflineAuthURLProtocol.handler.withLock { handler in
            handler = { request in
                switch request.url?.path {
                case "/auth/v1/recover":
                    let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                    #expect(parts?.queryItems?.first?.value == "housekeeping://auth/recovery")
                    return (200, Data("{}".utf8))
                case "/auth/v1/token":
                    #expect(request.url?.query == "grant_type=pkce")
                    return (200, sessionData)
                case "/auth/v1/user": return (200, userData)
                case "/auth/v1/logout": return (204, Data())
                default: throw URLError(.unsupportedURL)
                }
            }
        }
        let service = try recoveryService(storage)
        try await service.requestRecovery(email: "person@example.invalid")
        #expect(try await service.restoreRecovery() == .awaitingEmail)
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic"))
        #expect(try await service.acceptRecovery(url: url) == "person@example.invalid")
        #expect(try storage.retrieve(key: "session") == nil)
        #expect(try await service.restoreRecovery() == .passwordEntry(email: "person@example.invalid"))
        try await service.changePassword("synthetic-new-password")
        #expect(try await service.clearRecovery() == .complete)
        #expect(try await service.restoreRecovery() == nil)
        #expect(try storage.retrieve(key: "recovery-session") == nil)
        #expect(try storage.retrieve(key: "recovery-session-code-verifier") == nil)
    }

    @Test func unrelatedRecoveryAccountIsRejectedAndCleared() async throws {
        let storage = MemoryAuthStorage()
        let payload = try AuthClient.Configuration.jsonEncoder.encode(fixture())
        OfflineAuthURLProtocol.handler.withLock {
            $0 = { request in
                switch request.url?.path {
                case "/auth/v1/recover": return (200, Data("{}".utf8))
                case "/auth/v1/logout": return (204, Data())
                default: return (200, payload)
                }
            }
        }
        let service = try recoveryService(storage)
        try await service.requestRecovery(email: "other@example.invalid")
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic"))
        await #expect(throws: RecoveryFailure.invalidLink) { try await service.acceptRecovery(url: url) }
        #expect(try storage.retrieve(key: "recovery-session") == nil)
        #expect(try await service.restoreRecovery() == nil)
    }

    @Test func recoveryWithoutPendingRequestMakesNoNetworkCall() async throws {
        let service = try recoveryService(MemoryAuthStorage())
        OfflineAuthURLProtocol.handler.withLock {
            $0 = { _ in
                Issue.record("Unexpected network call")
                throw URLError(.badURL)
            }
        }
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic"))
        await #expect(throws: RecoveryFailure.invalidLink) { try await service.acceptRecovery(url: url) }
        await #expect(throws: RecoveryFailure.invalidLink) { try await service.changePassword("synthetic-password") }
    }

    private func recoveryService(_ storage: MemoryAuthStorage) throws -> SupabaseRecoveryService {
        let config = try AppConfiguration(
            values: [
                "HK_SUPABASE_URL": "https://offline.invalid",
                "HK_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_abcdefghijklmnopqrstuvwxyz",
            ], allowLocalHTTP: false)
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [OfflineAuthURLProtocol.self]
        return SupabaseRecoveryService(
            configuration: config, storage: storage, transport: URLSession(configuration: transport))
    }

    @Test(arguments: ["recovery-session", "pending-recovery", "recovery-session-code-verifier"])
    func failedPostExchangeStorageIsCleanedOrExplicitlyBlocked(key: String) async throws {
        let storage = MemoryAuthStorage()
        let payload = try AuthClient.Configuration.jsonEncoder.encode(fixture())
        OfflineAuthURLProtocol.handler.withLock {
            $0 = { request in
                switch request.url?.path {
                case "/auth/v1/recover": return (200, Data("{}".utf8))
                case "/auth/v1/logout": return (204, Data())
                default: return (200, payload)
                }
            }
        }
        let service = try recoveryService(storage)
        try await service.requestRecovery(email: "person@example.invalid")
        if key.hasSuffix("code-verifier") {
            storage.failedDeleteKeys.withLock { $0.insert(key) }
        } else {
            storage.failedWriteKeys.withLock { $0.insert(key) }
        }
        let url = try #require(URL(string: "housekeeping://auth/recovery?code=synthetic"))
        await #expect(throws: RecoveryFailure.protectedStorage) { try await service.acceptRecovery(url: url) }
        #expect(try storage.retrieve(key: "recovery-session") == nil)
        storage.failedDeleteKeys.withLock { $0.removeAll() }
        storage.failedWriteKeys.withLock { $0.removeAll() }
        #expect(try await recoveryService(storage).restoreRecovery() == nil)
        #expect(try storage.retrieve(key: "recovery-session-code-verifier") == nil)
    }

    @Test(arguments: [false, true])
    func expiredRecoveryClearsAllArtifacts(hasSession: Bool) async throws {
        let storage = MemoryAuthStorage()
        let session = fixture()
        let context = PendingRecovery(
            email: "person@example.invalid", requestedAt: Date().addingTimeInterval(-3601),
            userID: hasSession ? session.user.id : nil)
        try storage.store(key: "pending-recovery", value: JSONEncoder().encode(context))
        try storage.store(key: "recovery-session-code-verifier", value: Data(repeating: 65, count: 64))
        if hasSession { try storage.store(key: "recovery-session", value: JSONEncoder().encode(session)) }
        OfflineAuthURLProtocol.handler.withLock { $0 = { _ in (204, Data()) } }
        await #expect(throws: RecoveryFailure.invalidLink) { try await recoveryService(storage).restoreRecovery() }
        #expect(try await recoveryService(storage).restoreRecovery() == nil)
        #expect(try storage.retrieve(key: "recovery-session-code-verifier") == nil)
        #expect(try storage.retrieve(key: "recovery-session") == nil)
    }

    @Test func interruptedContextPromotionResumesAfterRelaunch() async throws {
        let storage = MemoryAuthStorage()
        let session = fixture()
        try storage.store(
            key: "pending-recovery",
            value: JSONEncoder().encode(PendingRecovery(email: "person@example.invalid", requestedAt: Date())))
        try storage.store(key: "recovery-session", value: JSONEncoder().encode(session))
        let user = try AuthClient.Configuration.jsonEncoder.encode(session.user)
        OfflineAuthURLProtocol.handler.withLock { $0 = { _ in (200, user) } }
        #expect(try await recoveryService(storage).restoreRecovery() == .passwordEntry(email: "person@example.invalid"))
    }
}
