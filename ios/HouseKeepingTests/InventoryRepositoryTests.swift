import Foundation
import Supabase
import Synchronization
import Testing

@testable import HouseKeeping

@Suite(.serialized) @MainActor
struct InventoryRepositoryTests {
    @Test func searchMapsWireDataAndPaginationWithoutRewritingQuery() async throws {
        let f = try Fixture()
        let item = String(decoding: try f.itemData(), as: UTF8.self)
        let payload = Data("{\"data\":[\(item)],\"nextOffset\":51}".utf8)
        OfflineInventoryURLProtocol.handler.withLock { handler in
            handler = { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/rest/v1/rpc/search_items")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
                let body = try input(request)
                #expect(body["query"] as? String == "%_\\ kettle")
                #expect(body["householdId"] as? String == f.householdID.uuidString)
                #expect(body["limit"] as? Int == 1)
                #expect(body["offset"] as? Int == 50)
                return (200, payload)
            }
        }
        let page = try await f.repository.search(
            .init(householdId: f.householdID, query: "%_\\ kettle", limit: 1, offset: 50))
        #expect(page.nextOffset == 51)
        let result = try #require(page.data.first)
        #expect(result.id == f.itemID)
        #expect(result.name == "Kettle")
        #expect(result.description == "Black kitchen kettle")
        #expect(result.brand == nil && result.model == nil && result.photoId == nil)
        #expect(result.purchasedOn?.rawValue == "2024-02-29")
        #expect(result.createdAt == Date(timeIntervalSince1970: 1_704_067_200))
        #expect(abs(result.updatedAt.timeIntervalSince(result.createdAt) - 0.123456) < 0.00001)
    }

    @Test func uncertainCreateRequiresExplicitRetryWithSameRequestAndFields() async throws {
        let f = try Fixture()
        let requestID = UUID()
        let payload = try f.itemData()
        let calls = Mutex(0)
        OfflineInventoryURLProtocol.handler.withLock { handler in
            handler = { request in
                #expect(request.url?.path == "/rest/v1/rpc/create_item")
                let body = try input(request)
                #expect(body["requestId"] as? String == requestID.uuidString)
                #expect(body["name"] as? String == "Kettle")
                #expect(body["fields"] == nil && body["createdBy"] == nil && body["photoId"] == nil)
                let count = calls.withLock {
                    $0 += 1
                    return $0
                }
                if count == 1 { throw URLError(.timedOut) }
                return (200, payload)
            }
        }
        let command = CreateItemInput(householdId: f.householdID, requestId: requestID, fields: .init(name: "Kettle"))
        await #expect(throws: InventoryFailure.unavailable) { try await f.repository.create(command) }
        #expect(calls.withLock { $0 } == 1)
        #expect(try await f.repository.create(command).id == f.itemID)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func updateKeepsExpectedVersionAndExplicitNullWhileDeleteAcceptsEmptyBody() async throws {
        let f = try Fixture()
        let payload = try f.itemData(overrides: ["version": 9])
        OfflineInventoryURLProtocol.handler.withLock { handler in
            handler = { request in
                let body = try input(request)
                #expect(body["id"] as? String == f.itemID.uuidString)
                if request.url?.lastPathComponent == "delete_item" {
                    #expect(body["expectedVersion"] as? Int == 9)
                    return (204, Data())
                }
                #expect(request.url?.lastPathComponent == "update_item")
                #expect(body["expectedVersion"] as? Int == 8)
                let fields = try #require(body["fields"] as? [String: Any])
                #expect(fields["description"] is NSNull)
                #expect(fields["brand"] == nil && fields["name"] == nil)
                return (200, payload)
            }
        }
        let result = try await f.repository.update(
            .init(id: f.itemID, expectedVersion: 8, fields: .init(description: .set(nil))))
        #expect(result.version == 9)
        try await f.repository.delete(id: f.itemID, expectedVersion: 9)
    }

    @Test func invalidInputsAndWrongHouseholdNeverReachNetwork() async throws {
        let f = try Fixture()
        OfflineInventoryURLProtocol.handler.withLock {
            $0 = { _ in
                Issue.record("Unexpected inventory request")
                return (500, Data())
            }
        }
        await #expect(throws: InventoryFailure.validation) {
            try await f.repository.create(
                .init(householdId: f.householdID, requestId: UUID(), fields: .init(name: " ")))
        }
        await #expect(throws: InventoryFailure.validation) {
            try await f.repository.search(.init(householdId: f.householdID, query: "", limit: 101))
        }
        await #expect(throws: InventoryFailure.validation) {
            try await f.repository.update(.init(id: f.itemID, expectedVersion: 1, fields: .init()))
        }
        await #expect(throws: InventoryFailure.validation) {
            try await f.repository.delete(id: f.itemID, expectedVersion: 0)
        }
        await #expect(throws: InventoryFailure.validation) {
            try await f.repository.removePhoto(itemID: f.itemID, expectedVersion: 9_007_199_254_740_991)
        }
        await #expect(throws: InventoryFailure.validation) {
            try await f.repository.update(
                .init(id: f.itemID, expectedVersion: 9_007_199_254_740_991, fields: .init(name: "Kettle")))
        }
        await #expect(throws: InventoryFailure.notFound) {
            try await f.repository.search(.init(householdId: UUID(), query: ""))
        }
        await #expect(throws: InventoryFailure.notFound) {
            try await f.repository.create(.init(householdId: UUID(), requestId: UUID(), fields: .init(name: "Kettle")))
        }
    }

    @Test func photoRemovalUsesVersionedContractAndRejectsUnremovedOrInvalidResults() async throws {
        let f = try Fixture()
        for version in [8, 9] {
            let payload = try f.itemData(overrides: ["version": version])
            OfflineInventoryURLProtocol.handler.withLock { handler in
                handler = { request in
                    #expect(request.url?.lastPathComponent == "remove_item_photo")
                    let body = try input(request)
                    #expect(body["itemId"] as? String == f.itemID.uuidString)
                    #expect(body["expectedVersion"] as? Int == 8)
                    #expect(body["id"] == nil)
                    return (200, payload)
                }
            }
            #expect(try await f.repository.removePhoto(itemID: f.itemID, expectedVersion: 8).version == version)
        }
        for overrides: [String: Any] in [
            ["photoId": UUID().uuidString], ["version": 10], ["id": UUID().uuidString],
            ["householdId": UUID().uuidString],
        ] {
            let payload = try f.itemData(overrides: overrides)
            OfflineInventoryURLProtocol.handler.withLock { $0 = { _ in (200, payload) } }
            await #expect(throws: InventoryFailure.invalidResponse) {
                try await f.repository.removePhoto(itemID: f.itemID, expectedVersion: 8)
            }
        }
    }

    @Test func serverErrorsAreNormalizedAndNeverExposeResponseText() async throws {
        let f = try Fixture()
        let cases: [(Int, String, InventoryFailure)] = [
            (401, "PT401", .unauthenticated), (401, "PGRST301", .unauthenticated), (403, "42501", .forbidden),
            (404, "PT404", .notFound), (409, "PT409", .conflict), (422, "PT422", .validation),
            (500, "XX000", .unavailable),
        ]
        for (status, code, expected) in cases {
            let payload = Data(
                "{\"code\":\"\(code)\",\"message\":\"sensitive SQL or token\",\"details\":null,\"hint\":null}".utf8)
            OfflineInventoryURLProtocol.handler.withLock { $0 = { _ in (status, payload) } }
            await #expect(throws: expected) { try await f.repository.get(id: f.itemID) }
        }
    }

    @Test func malformedForeignAndMismatchedResponsesAreRejected() async throws {
        let f = try Fixture()
        var responses = [Data("{}".utf8), Data("not JSON".utf8)]
        for overrides: [String: Any] in [
            ["householdId": UUID().uuidString], ["id": UUID().uuidString], ["version": 0],
            ["purchasedOn": "2025-02-29"], ["createdAt": "not an instant"], ["name": ""], ["description": 7],
        ] {
            responses.append(try f.itemData(overrides: overrides))
        }
        for payload in responses {
            OfflineInventoryURLProtocol.handler.withLock { $0 = { _ in (200, payload) } }
            await #expect(throws: InventoryFailure.invalidResponse) { try await f.repository.get(id: f.itemID) }
        }
    }

    @Test func definitePhotoReadinessRejectionHasItsOwnRecoveryCategory() async throws {
        let f = try Fixture()
        let body = Data("{\"code\":\"PT409\",\"message\":\"PHOTO_NOT_READY\",\"details\":null,\"hint\":null}".utf8)
        OfflineInventoryURLProtocol.handler.withLock { $0 = { _ in (409, body) } }
        await #expect(throws: InventoryFailure.photoNotReady) {
            try await f.repository.create(
                .init(
                    householdId: f.householdID, requestId: UUID(),
                    fields: .init(name: "Photo purchase"), photoId: UUID()))
        }
    }

    @Test func nonJSONGatewayErrorsKeepAuthSemanticsWithoutExposingBody() async throws {
        let f = try Fixture()
        for (status, expected): (Int, InventoryFailure) in [
            (401, .unauthenticated), (403, .forbidden), (503, .unavailable),
        ] {
            OfflineInventoryURLProtocol.handler.withLock {
                $0 = { _ in (status, Data("private gateway response".utf8)) }
            }
            await #expect(throws: expected) { try await f.repository.get(id: f.itemID) }
        }
    }

    @Test func invalidPaginationAndUpdateVersionAreRejected() async throws {
        let f = try Fixture()
        let item = String(decoding: try f.itemData(), as: UTF8.self)
        for json in [
            "{\"data\":[],\"nextOffset\":1}", "{\"data\":[\(item)],\"nextOffset\":0}",
            "{\"data\":[\(item),\(item)],\"nextOffset\":null}",
        ] {
            let payload = Data(json.utf8)
            OfflineInventoryURLProtocol.handler.withLock { $0 = { _ in (200, payload) } }
            await #expect(throws: InventoryFailure.invalidResponse) {
                try await f.repository.search(.init(householdId: f.householdID, query: "", limit: 1))
            }
        }
        let payload = try f.itemData()
        OfflineInventoryURLProtocol.handler.withLock { $0 = { _ in (200, payload) } }
        await #expect(throws: InventoryFailure.invalidResponse) {
            try await f.repository.update(.init(id: f.itemID, expectedVersion: 8, fields: .init(name: "Kettle")))
        }
    }

    @Test func signedOutOrChangedAccountAndStorageFailureDoNotSendInventory() async throws {
        let f = try Fixture()
        OfflineInventoryURLProtocol.handler.withLock {
            $0 = { _ in
                Issue.record("Unexpected request")
                return (500, Data())
            }
        }
        f.storage.failWrites.withLock { $0 = true }
        await #expect(throws: InventoryFailure.protectedStorage) { try await f.repository.get(id: f.itemID) }
        f.storage.failWrites.withLock { $0 = false }
        try f.storage.remove(key: "session")
        await #expect(throws: InventoryFailure.unauthenticated) { try await f.repository.get(id: f.itemID) }
        try f.storage.store(key: "session", value: JSONEncoder().encode(SupabaseAuthServiceTests().fixture()))
        await #expect(throws: InventoryFailure.unauthenticated) { try await f.repository.get(id: f.itemID) }
    }

    @Test func cancellationIsNotPresentedAsServerFailure() async throws {
        let f = try Fixture()
        OfflineInventoryURLProtocol.handler.withLock { $0 = { _ in throw URLError(.cancelled) } }
        await #expect(throws: CancellationError.self) { try await f.repository.get(id: f.itemID) }
        OfflineInventoryURLProtocol.handler.withLock {
            $0 = { _ in
                Issue.record("Cancelled task sent request")
                return (500, Data())
            }
        }
        let task = Task { try await f.repository.get(id: f.itemID) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func accountSwitchRejectsLateResultsAndOldRepository() async throws {
        let f = try Fixture()
        let payload = try f.itemData()
        var nextSession = SupabaseAuthServiceTests().fixture()
        nextSession.accessToken = "synthetic-next-access"
        let nextSessionData = try AuthClient.Configuration.jsonEncoder.encode(nextSession)
        let sentTokens = Mutex<[String]>([])
        OfflineInventoryURLProtocol.holdNextGet.withLock { $0 = true }
        defer {
            OfflineInventoryURLProtocol.holdNextGet.withLock { $0 = false }
            OfflineInventoryURLProtocol.pending.withLock { pending in
                let completion = pending
                pending = nil
                return completion
            }?()
        }
        OfflineInventoryURLProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/auth/v1/logout" { return (204, Data()) }
                if request.url?.path == "/auth/v1/token" { return (200, nextSessionData) }
                sentTokens.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "missing") }
                return (200, payload)
            }
        }
        let pendingGet = Task { try await f.repository.get(id: f.itemID) }
        for _ in 0..<1000 {
            if OfflineInventoryURLProtocol.pending.withLock({ $0 != nil }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(try await f.auth.signOut() == .complete)
        _ = try await f.auth.signIn(email: "next@example.invalid", password: "synthetic")
        let completion = try #require(
            OfflineInventoryURLProtocol.pending.withLock { pending in
                let completion = pending
                pending = nil
                return completion
            })
        completion()
        await #expect(throws: InventoryFailure.unauthenticated) { try await pendingGet.value }
        await #expect(throws: InventoryFailure.unauthenticated) { try await f.repository.get(id: f.itemID) }
        let newRepository = SupabaseInventoryRepository(
            auth: f.auth, accountID: nextSession.user.id, householdID: f.householdID)
        #expect(try await newRepository.get(id: f.itemID).id == f.itemID)
        #expect(sentTokens.withLock { $0 } == ["Bearer synthetic-access", "Bearer synthetic-next-access"])
    }

    private struct Fixture {
        let householdID = UUID()
        let itemID = UUID()
        let storage = MemoryAuthStorage()
        let auth: SupabaseAuthService
        let repository: SupabaseInventoryRepository

        @MainActor init() throws {
            let configuration = try AppConfiguration(
                values: [
                    "HK_SUPABASE_URL": "https://offline.invalid",
                    "HK_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_abcdefghijklmnopqrstuvwxyz",
                ], allowLocalHTTP: false)
            let transport = URLSessionConfiguration.ephemeral
            transport.protocolClasses = [OfflineInventoryURLProtocol.self]
            let session = SupabaseAuthServiceTests().fixture()
            try storage.store(key: "session", value: JSONEncoder().encode(session))
            auth = SupabaseAuthService(
                configuration: configuration, storage: storage, transport: URLSession(configuration: transport))
            repository = SupabaseInventoryRepository(auth: auth, accountID: session.user.id, householdID: householdID)
        }

        func itemData(overrides: [String: Any] = [:]) throws -> Data {
            var row: [String: Any] = [
                "id": itemID.uuidString, "householdId": householdID.uuidString, "name": "Kettle",
                "description": "Black kitchen kettle", "brand": NSNull(), "model": NSNull(), "photoId": NSNull(),
                "purchasedOn": "2024-02-29", "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00.123456+00:00", "version": 8,
            ]
            row.merge(overrides) { _, new in new }
            return try JSONSerialization.data(withJSONObject: row)
        }
    }
}

private nonisolated func input(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["p_input"])
    return try #require(json["p_input"] as? [String: Any])
}

private final class OfflineInventoryURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> (Int, Data))?>(nil)
    static let holdNextGet = Mutex(false)
    static let pending = Mutex<(@Sendable () -> Void)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler.withLock({ $0 }), let url = request.url, url.host() == "offline.invalid"
            else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            let response = try #require(
                HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            let complete: @Sendable () -> Void = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            let hold =
                request.url?.lastPathComponent == "get_item"
                && Self.holdNextGet.withLock { value in
                    let previous = value
                    value = false
                    return previous
                }
            if hold { Self.pending.withLock { $0 = complete } } else { complete() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
