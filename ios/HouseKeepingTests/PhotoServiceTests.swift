import CryptoKit
import Foundation
import Supabase
import Synchronization
import Testing

@testable import HouseKeeping

@Suite(.serialized) @MainActor
struct PhotoServiceTests {
    @Test func reserveUploadCompleteAndDiscardUsePrivateAuthenticatedRoutes() async throws {
        let f = try Fixture()
        let requestID = UUID()
        let prepared = try await PhotoPreparation().prepare(photoFixtureJPEG(width: 32, height: 24))
        let draft = ImageDraft(owner: f.owner, prepared: prepared)
        let calls = Mutex<[String]>([])
        PhotoURLProtocol.handler.withLock { handler in
            handler = { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
                #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                let path = try #require(request.url?.path)
                calls.withLock { $0.append(path) }
                if path == "/functions/v1/media/photos" {
                    let body = try JSONSerialization.jsonObject(with: photoRequestBody(request)) as? [String: String]
                    #expect(body?["householdId"] == f.owner.householdID.uuidString)
                    #expect(body?["requestId"] == requestID.uuidString)
                    return (201, try f.reservationData())
                }
                if path.hasPrefix("/storage/v1/object/") {
                    #expect(request.httpMethod == "POST")
                    #expect(request.value(forHTTPHeaderField: "x-upsert") == "false")
                    #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
                    #expect(try photoRequestBody(request) == prepared.jpegData)
                    return (200, Data("{}".utf8))
                }
                if path.hasSuffix("/completion") {
                    #expect(try photoRequestBody(request) == Data("{}".utf8))
                    return (200, Data("{\"photoId\":\"\(f.photoID)\",\"state\":\"READY\"}".utf8))
                }
                #expect(request.httpMethod == "DELETE")
                return (204, Data())
            }
        }
        let reservation = try await f.service.reserve(requestID: requestID)
        try await f.service.upload(draft, to: reservation)
        try await f.service.complete(reservation)
        try await f.service.discard(photoID: f.photoID)
        #expect(calls.withLock { $0 }.count == 4)
    }

    @Test func attachedDownloadAcceptsOtherSpouseAndVerifiesExactBytes() async throws {
        let f = try Fixture()
        let data = try await PhotoPreparation().prepare(photoFixtureJPEG(width: 32, height: 24)).jpegData
        let otherSpouse = UUID()
        let key = PhotoReservation.objectKey(
            householdID: f.owner.householdID, uploaderID: otherSpouse, photoID: f.photoID)
        PhotoURLProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/rest/v1/photos" {
                    #expect(request.url?.query()?.contains("limit=1") == true)
                    return (200, try f.metadata(data: data, uploader: otherSpouse))
                }
                #expect(request.httpMethod == "GET")
                #expect(request.url?.path == "/storage/v1/object/purchase-photos/\(key)")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
                return (200, data)
            }
        }
        #expect(try await f.service.download(photoID: f.photoID) == data)
    }

    @Test func foreignPathsWrongStatesCorruptChecksumsAndLargeResponsesAreRejected() async throws {
        let f = try Fixture()
        let data = try photoFixtureJPEG(width: 32, height: 24)
        let forbiddenDownload = Mutex(false)
        for change: [String: Any] in [
            ["household_id": UUID().uuidString], ["id": UUID().uuidString],
            ["state": "READY"], ["object_key": "../../private"], ["byte_size": 5 * 1024 * 1024 + 1],
        ] {
            let metadata = try f.metadata(data: data, overrides: change)
            PhotoURLProtocol.handler.withLock { handler in
                handler = { request in
                    if request.url?.path != "/rest/v1/photos" { forbiddenDownload.withLock { $0 = true } }
                    return (200, metadata)
                }
            }
            await #expect(throws: PhotoFailure.invalidResponse) { try await f.service.download(photoID: f.photoID) }
        }
        #expect(!forbiddenDownload.withLock { $0 })
        PhotoURLProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/rest/v1/photos" { return (200, try f.metadata(data: data)) }
                return (200, Data(repeating: 0, count: data.count))
            }
        }
        await #expect(throws: PhotoFailure.invalidResponse) { try await f.service.download(photoID: f.photoID) }
        PhotoURLProtocol.handler.withLock { $0 = { _ in (200, Data(repeating: 0, count: 64 * 1024 + 1)) } }
        await #expect(throws: PhotoFailure.invalidResponse) { try await f.service.reserve(requestID: UUID()) }
    }

    @Test func reservationValidationAndExpiryPreventUploadsWithoutLosingDraftBytes() async throws {
        let f = try Fixture()
        let prepared = try await PhotoPreparation().prepare(photoFixtureJPEG(width: 32, height: 24))
        let draft = ImageDraft(owner: f.owner, prepared: prepared)
        PhotoURLProtocol.handler.withLock {
            $0 = { _ in
                Issue.record("Unexpected upload")
                return (500, Data())
            }
        }
        await #expect(throws: PhotoFailure.expired) {
            try await f.service.upload(draft, to: .init(photoId: f.photoID, objectKey: f.key, expiresAt: .distantPast))
        }
        await #expect(throws: PhotoFailure.invalidResponse) {
            try await f.service.upload(
                draft, to: .init(photoId: f.photoID, objectKey: "foreign.jpg", expiresAt: .distantFuture))
        }
        #expect(draft.jpegData == prepared.jpegData)
        PhotoURLProtocol.handler.withLock {
            $0 = { _ in (201, try f.reservationData(key: "https://foreign.invalid/file")) }
        }
        await #expect(throws: PhotoFailure.invalidResponse) { try await f.service.reserve(requestID: UUID()) }
    }

    @Test func errorsAreNormalizedAndMutationsNeverRetryAutomatically() async throws {
        let f = try Fixture()
        let cases: [(Int, String, PhotoFailure)] = [
            (401, "UNAUTHENTICATED", .unauthenticated), (403, "", .forbidden), (404, "NOT_FOUND", .notFound),
            (409, "RESERVATION_EXPIRED", .expired), (409, "UPLOAD_INCOMPLETE", .uploadIncomplete),
            (409, "CONFLICT", .conflict), (422, "INVALID_IMAGE", .validation), (500, "secret detail", .unavailable),
        ]
        for (status, code, expected) in cases {
            PhotoURLProtocol.handler.withLock {
                $0 = { _ in (status, Data("{\"code\":\"\(code)\",\"message\":\"secret\"}".utf8)) }
            }
            await #expect(throws: expected) { try await f.service.reserve(requestID: UUID()) }
        }
        let calls = Mutex(0)
        PhotoURLProtocol.handler.withLock { handler in
            handler = { _ in
                calls.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
        }
        await #expect(throws: PhotoFailure.unavailable) { try await f.service.reserve(requestID: UUID()) }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func staleServiceAndLateResponseCannotCrossSignOut() async throws {
        let f = try Fixture()
        PhotoURLProtocol.holdNext.withLock { $0 = true }
        PhotoURLProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/auth/v1/logout" { return (204, Data()) }
                return (201, try f.reservationData())
            }
        }
        let pending = Task { try await f.service.reserve(requestID: UUID()) }
        for _ in 0..<1000 {
            if PhotoURLProtocol.pending.withLock({ $0 != nil }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(try await f.auth.signOut() == .complete)
        let completion = try #require(
            PhotoURLProtocol.pending.withLock { value in
                let result = value
                value = nil
                return result
            })
        completion()
        await #expect(throws: PhotoFailure.unauthenticated) { try await pending.value }
        await #expect(throws: PhotoFailure.unauthenticated) { try await f.service.reserve(requestID: UUID()) }
    }

    private struct Fixture {
        let photoID = UUID()
        let owner: DraftOwner
        let auth: SupabaseAuthService
        let service: SupabasePhotoService
        var key: String {
            PhotoReservation.objectKey(householdID: owner.householdID, uploaderID: owner.accountID, photoID: photoID)
        }

        @MainActor init() throws {
            let configuration = try AppConfiguration(
                values: [
                    "HK_SUPABASE_URL": "https://offline.invalid",
                    "HK_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_abcdefghijklmnopqrstuvwxyz",
                ], allowLocalHTTP: false)
            let transport = URLSessionConfiguration.ephemeral
            transport.protocolClasses = [PhotoURLProtocol.self]
            let storage = MemoryAuthStorage()
            let session = SupabaseAuthServiceTests().fixture()
            try storage.store(key: "session", value: JSONEncoder().encode(session))
            owner = DraftOwner(accountID: session.user.id, householdID: UUID())
            auth = SupabaseAuthService(
                configuration: configuration, storage: storage, transport: URLSession(configuration: transport))
            service = SupabasePhotoService(auth: auth, owner: owner)
        }

        func reservationData(key: String? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "photoId": photoID.uuidString, "objectKey": key ?? self.key,
                "expiresAt": Date().addingTimeInterval(3600).ISO8601Format(),
            ])
        }

        func metadata(data: Data, uploader: UUID? = nil, overrides: [String: Any] = [:]) throws -> Data {
            var value: [String: Any] = [
                "id": photoID.uuidString, "household_id": owner.householdID.uuidString,
                "uploader_user_id": (uploader ?? owner.accountID).uuidString, "state": "ATTACHED",
                "byte_size": data.count,
                "checksum": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "object_key": PhotoReservation.objectKey(
                    householdID: owner.householdID, uploaderID: uploader ?? owner.accountID, photoID: photoID),
            ]
            value.merge(overrides) { _, new in new }
            return try JSONSerialization.data(withJSONObject: [value])
        }
    }
}

private nonisolated func photoRequestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private final class PhotoURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> (Int, Data))?>(nil)
    static let holdNext = Mutex(false)
    static let pending = Mutex<(@Sendable () -> Void)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler.withLock({ $0 }), let url = request.url, url.host() == "offline.invalid"
            else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            let complete: @Sendable () -> Void = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            let hold = Self.holdNext.withLock { value in
                let result = value
                value = false
                return result
            }
            if hold { Self.pending.withLock { $0 = complete } } else { complete() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
