import Foundation
import Supabase
import Synchronization
import Testing

@testable import HouseKeeping

@Suite(.serialized) @MainActor
struct SupabaseAuthServiceTests {
    @Test func signInPersistsAndFetchesHousehold() async throws {
        let storage = MemoryAuthStorage()
        let session = fixture()
        let payload = try AuthClient.Configuration.jsonEncoder.encode(session)
        let householdID = UUID()
        OfflineAuthURLProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/auth/v1/token" {
                    #expect(request.url?.query == "grant_type=password")
                    return (200, payload)
                }
                #expect(request.url?.path == "/rest/v1/rpc/get_household")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
                return (200, Data("{\"householdId\":\"\(householdID)\",\"name\":\"Our home\"}".utf8))
            }
        }
        let service = try service(storage)
        #expect(try await service.signIn(email: "person@example.invalid", password: "synthetic").id == session.user.id)
        #expect(try storage.retrieve(key: "session") != nil)
        #expect(try await service.household().householdId == householdID)
        #expect(try await service.restore()?.id == session.user.id)
    }

    @Test func logoutSendsLocalRevocationBeforeRemovingCredentials() async throws {
        let storage = MemoryAuthStorage()
        try storage.store(key: "session", value: JSONEncoder().encode(fixture()))
        let requests = Mutex(0)
        OfflineAuthURLProtocol.handler.withLock { handler in
            handler = { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/auth/v1/logout")
                #expect(request.url?.query == "scope=local")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
                requests.withLock { $0 += 1 }
                return (204, Data())
            }
        }
        let service = try service(storage)
        #expect(try await service.signOut() == .complete)
        #expect(requests.withLock { $0 } == 1)
        #expect(try storage.retrieve(key: "session") == nil)
    }

    @Test func offlineLogoutStillRemovesCredentials() async throws {
        let storage = MemoryAuthStorage()
        try storage.store(key: "session", value: JSONEncoder().encode(fixture()))
        OfflineAuthURLProtocol.handler.withLock { $0 = { _ in throw URLError(.notConnectedToInternet) } }
        let service = try service(storage)
        #expect(try await service.signOut() == .localOnly)
        #expect(try storage.retrieve(key: "session") == nil)
    }

    @Test func swallowedSDKWriteFailureIsSurfaced() async throws {
        let storage = MemoryAuthStorage()
        storage.failWrites.withLock { $0 = true }
        let payload = try AuthClient.Configuration.jsonEncoder.encode(fixture())
        OfflineAuthURLProtocol.handler.withLock { $0 = { _ in (200, payload) } }
        let service = try service(storage)
        await #expect(throws: AuthenticationFailure.protectedStorage) {
            try await service.signIn(email: "person@example.invalid", password: "synthetic")
        }
    }

    @Test func failedDeletionIsNotReportedAsSuccessfulLogout() async throws {
        let storage = MemoryAuthStorage()
        try storage.store(key: "session", value: JSONEncoder().encode(fixture()))
        storage.failDeletes.withLock { $0 = true }
        OfflineAuthURLProtocol.handler.withLock { $0 = { _ in (204, Data()) } }
        let service = try service(storage)
        await #expect(throws: AuthenticationFailure.protectedStorage) { try await service.signOut() }
        #expect(try storage.retrieve(key: "session") != nil)
    }

    @Test func expiredSessionRefreshPersistsRotatedCredential() async throws {
        let storage = MemoryAuthStorage()
        var expired = fixture()
        expired.expiresAt = 0
        try storage.store(key: "session", value: JSONEncoder().encode(expired))
        var renewed = expired
        renewed.expiresAt = Date().timeIntervalSince1970 + 3600
        renewed.refreshToken = "synthetic-rotated"
        let payload = try AuthClient.Configuration.jsonEncoder.encode(renewed)
        OfflineAuthURLProtocol.handler.withLock { handler in
            handler = { request in
                #expect(request.url?.query == "grant_type=refresh_token")
                return (200, payload)
            }
        }
        let service = try service(storage)
        #expect(try await service.restore()?.id == expired.user.id)
        let stored = try #require(try storage.retrieve(key: "session"))
        #expect(try JSONDecoder().decode(Session.self, from: stored).refreshToken == "synthetic-rotated")
    }

    @Test func errorsAreNormalizedWithoutServerMessages() async throws {
        let storage = MemoryAuthStorage()
        OfflineAuthURLProtocol.handler.withLock {
            $0 = { _ in (400, Data(#"{"code":"invalid_credentials","msg":"sensitive server response"}"#.utf8)) }
        }
        let service = try service(storage)
        await #expect(throws: AuthenticationFailure.invalidCredentials) {
            try await service.signIn(email: "person@example.invalid", password: "synthetic")
        }
    }

    private func service(_ storage: MemoryAuthStorage) throws -> SupabaseAuthService {
        let configuration = try AppConfiguration(
            values: [
                "HK_SUPABASE_URL": "https://offline.invalid",
                "HK_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_abcdefghijklmnopqrstuvwxyz",
            ], allowLocalHTTP: false)
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [OfflineAuthURLProtocol.self]
        return SupabaseAuthService(
            configuration: configuration, storage: storage, transport: URLSession(configuration: transport))
    }

    func fixture() -> Session {
        Session(
            accessToken: "synthetic-access", tokenType: "bearer", expiresIn: 3600,
            expiresAt: Date().timeIntervalSince1970 + 3600, refreshToken: "synthetic-refresh",
            user: User(
                id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated",
                email: "person@example.invalid", createdAt: Date(), updatedAt: Date()))
    }
}

final class MemoryAuthStorage: AuthLocalStorage, Sendable {
    let values = Mutex<[String: Data]>([:])
    let failWrites = Mutex(false)
    let failDeletes = Mutex(false)
    let failedWriteKeys = Mutex<Set<String>>([])
    let failedDeleteKeys = Mutex<Set<String>>([])
    func store(key: String, value: Data) throws {
        if failWrites.withLock({ $0 }) || failedWriteKeys.withLock({ $0.contains(key) }) {
            throw AuthenticationFailure.protectedStorage
        }
        values.withLock { $0[key] = value }
    }
    func retrieve(key: String) throws -> Data? { values.withLock { $0[key] } }
    func remove(key: String) throws {
        if failDeletes.withLock({ $0 }) || failedDeleteKeys.withLock({ $0.contains(key) }) {
            throw AuthenticationFailure.protectedStorage
        }
        values.withLock { $0[key] = nil }
    }
}

final class OfflineAuthURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> (Int, Data))?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler.withLock({ $0 }), let url = request.url,
                url.host() == "offline.invalid"
            else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])
            else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
