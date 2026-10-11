import Foundation
import Synchronization
import Testing

@testable import HouseKeeping

@Suite(.serialized) @MainActor
struct RecognitionFlowTests {
    @Test func suggestionRemainsEditableAndRequiresExplicitSave() async throws {
        let fixture = try await Fixture()
        #expect(fixture.store.drafts.edit(.init(name: "", quantity: 4, restockLimit: 3)))
        fixture.client.result = .success(
            .suggested(
                ProductSuggestion(
                    name: "Suggested kettle", description: "Black countertop kettle",
                    brand: nil, model: nil)))

        #expect(await fixture.store.requestRecognition() != nil)
        #expect(fixture.store.recognitionState == .suggested(.provider))
        #expect(fixture.store.drafts.draft?.fields.name == "Suggested kettle")
        #expect(fixture.store.drafts.draft?.fields.quantity == 4)
        #expect(fixture.store.drafts.draft?.fields.restockLimit == 3)
        #expect(fixture.repository.inputs.isEmpty)

        var edited = try #require(fixture.store.drafts.draft?.fields)
        edited.name = "My edited kettle"
        edited.brand = "Confirmed by me"
        #expect(fixture.store.drafts.edit(edited))
        let saved = try #require(await fixture.store.saveDraft())
        #expect(saved.name == "My edited kettle" && saved.brand == "Confirmed by me")
        #expect(fixture.repository.inputs.count == 1)
        #expect(fixture.repository.inputs.first?.fields.quantity == 4)
        #expect(fixture.repository.inputs.first?.fields.restockLimit == 3)
        #expect(fixture.repository.inputs.first?.photoId == fixture.client.calls.first?.photoID)
    }

    @Test func timeoutRenewsRequestOnlyOnExplicitRetryAndManualSaveStillWorks() async throws {
        let fixture = try await Fixture()
        fixture.client.result = .failure(RecognitionFailure.retryRequired)
        #expect(await fixture.store.requestRecognition() == nil)
        #expect(fixture.store.recognitionState == .failed(.retryRequired))
        let firstRequest = try #require(fixture.client.calls.first?.requestID)
        #expect(fixture.storage.image?.upload?.recognitionRequestId == firstRequest)
        #expect(fixture.storage.image?.upload?.recognitionRetryRequired == true)

        fixture.client.result = .failure(RecognitionFailure.inProgress)
        #expect(await fixture.store.requestRecognition() == nil)
        let secondRequest = try #require(fixture.client.calls.last?.requestID)
        #expect(secondRequest != firstRequest)
        #expect(fixture.storage.image?.upload?.recognitionRequestId == secondRequest)
        #expect(fixture.storage.image?.upload?.recognitionRetryRequired != true)

        fixture.store.continueManually()
        #expect(fixture.store.drafts.edit(.init(name: "Manual after timeout")))
        #expect(await fixture.store.saveDraft()?.name == "Manual after timeout")
    }

    @Test func lateSuggestionDoesNotOverwriteFieldsEditedWhileRequestRuns() async throws {
        let fixture = try await Fixture()
        fixture.client.hold = true
        let recognition = Task { await fixture.store.requestRecognition() }
        await waitUntil { fixture.client.calls.count == 1 }
        #expect(fixture.store.recognitionState == .recognizing(.provider))
        #expect(fixture.store.drafts.edit(.init(name: "Typed while waiting")))
        fixture.client.finish(
            .success(
                .suggested(
                    ProductSuggestion(name: "Late kettle", description: nil, brand: nil, model: nil))))
        _ = await recognition.value
        #expect(fixture.store.drafts.draft?.fields.name == "Typed while waiting")
        #expect(fixture.store.recognitionState == .stale)
        #expect(fixture.repository.inputs.isEmpty)
    }

    @Test func uncertainTransportFailureReusesPersistedRequestAfterReconstruction() async throws {
        let fixture = try await Fixture()
        fixture.client.result = .failure(RecognitionFailure.unavailable)
        #expect(await fixture.store.requestRecognition() == nil)
        let originalRequest = try #require(fixture.client.calls.first?.requestID)
        #expect(await fixture.store.retire())

        let replayClient = ControlledRecognitionClient(owner: fixture.storage.owner)
        replayClient.result = .failure(RecognitionFailure.inProgress)
        let restored = InventoryStore(
            repository: fixture.repository, draftStorage: fixture.storage,
            photoService: fixture.photos, recognitionClient: replayClient)
        await restored.drafts.restore()
        await restored.photoDraft?.restore()
        #expect(await restored.requestRecognition() == nil)
        #expect(replayClient.calls.first?.requestID == originalRequest)
    }

    @Test func manualContinuationAndDiscardInvalidateLateResults() async throws {
        let fixture = try await Fixture()
        fixture.client.hold = true
        let recognition = Task { await fixture.store.requestRecognition() }
        await waitUntil { fixture.client.calls.count == 1 }
        fixture.store.continueManually()
        #expect(fixture.store.recognitionState == .manual)
        fixture.client.finish(
            .success(
                .suggested(
                    ProductSuggestion(name: "Dismissed result", description: nil, brand: nil, model: nil))))
        _ = await recognition.value
        #expect(fixture.store.drafts.draft?.fields.name == "")
        #expect(await fixture.store.discardDraft(confirmed: true))
        #expect(fixture.store.drafts.draft == nil && fixture.storage.image == nil)
    }

    @Test func liveClientUsesAuthenticatedBoundedRouteAndValidatesOutput() async throws {
        let fixture = try HTTPFixture()
        let requestID = UUID()
        RecognitionURLProtocol.handler.withLock { handler in
            handler = { request in
                #expect(request.url?.path == "/functions/v1/recognitions")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
                #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
                let input = try JSONDecoder().decode(RecognitionInputFixture.self, from: try requestBody(request))
                #expect(input.photoId == fixture.photoID && input.requestId == requestID)
                return (
                    200,
                    Data(
                        """
                        {"status":"SUGGESTED","analysisId":"\(UUID())","photoId":"\(fixture.photoID)","suggestion":{"name":"Kettle","description":null,"brand":null,"model":null}}
                        """.utf8
                    )
                )
            }
        }
        #expect(
            try await fixture.client.recognize(photoID: fixture.photoID, requestID: requestID)
                == .suggested(ProductSuggestion(name: "Kettle", description: nil, brand: nil, model: nil)))

        for (status, code, expected): (Int, String, RecognitionFailure) in [
            (409, "RECOGNITION_IN_PROGRESS", .inProgress),
            (409, "RECOGNITION_RETRY_REQUIRED", .retryRequired),
            (429, "QUOTA_EXCEEDED", .quotaExceeded),
            (502, "PROVIDER_REFUSAL", .providerRefusal),
            (502, "INVALID_PROVIDER_RESPONSE", .invalidResponse),
            (503, "RECOGNITION_UNAVAILABLE", .unavailable),
            (504, "PROVIDER_TIMEOUT", .retryRequired),
        ] {
            RecognitionURLProtocol.handler.withLock {
                $0 = { _ in (status, Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)) }
            }
            await #expect(throws: expected) {
                try await fixture.client.recognize(photoID: fixture.photoID, requestID: UUID())
            }
        }
    }

    @Test func liveClientRejectsForeignMalformedAndOversizedResponses() async throws {
        let fixture = try HTTPFixture()
        for response in [
            Data(
                """
                {"status":"SUGGESTED","analysisId":"\(UUID())","photoId":"\(UUID())","suggestion":{"name":"Kettle","description":null,"brand":null,"model":null}}
                """.utf8),
            Data(
                """
                {"status":"SUGGESTED","analysisId":"\(UUID())","photoId":"\(fixture.photoID)","suggestion":{"name":"","description":null,"brand":null,"model":null}}
                """.utf8),
            Data("not json".utf8),
            Data(repeating: 0, count: 64 * 1_024 + 1),
        ] {
            RecognitionURLProtocol.handler.withLock { $0 = { _ in (200, response) } }
            await #expect(throws: RecognitionFailure.invalidResponse) {
                try await fixture.client.recognize(photoID: fixture.photoID, requestID: UUID())
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Expected controlled recognition operation did not start")
    }

    private struct Fixture {
        let storage: RecognitionStorage
        let repository: RecognitionRepository
        let photos: RecognitionPhotoService
        let client: ControlledRecognitionClient
        let store: InventoryStore

        @MainActor init() async throws {
            storage = RecognitionStorage()
            repository = RecognitionRepository(owner: storage.owner)
            photos = RecognitionPhotoService(owner: storage.owner)
            client = ControlledRecognitionClient(owner: storage.owner)
            store = InventoryStore(
                repository: repository, draftStorage: storage, photoService: photos,
                recognitionClient: client)
            await store.drafts.restore()
            await store.photoDraft?.restore()
            #expect(store.beginDraft())
            await store.photoDraft?.importData(try photoFixtureJPEG(width: 32, height: 24))
            #expect(store.photoDraft?.draft != nil)
        }
    }

    private struct HTTPFixture {
        let photoID = UUID()
        let client: SupabaseRecognitionClient

        @MainActor init() throws {
            let configuration = try AppConfiguration(
                values: [
                    "HK_SUPABASE_URL": "https://offline.invalid",
                    "HK_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_abcdefghijklmnopqrstuvwxyz",
                ], allowLocalHTTP: false)
            let transport = URLSessionConfiguration.ephemeral
            transport.protocolClasses = [RecognitionURLProtocol.self]
            let storage = MemoryAuthStorage()
            let session = SupabaseAuthServiceTests().fixture()
            try storage.store(key: "session", value: JSONEncoder().encode(session))
            let auth = SupabaseAuthService(
                configuration: configuration, storage: storage,
                transport: URLSession(configuration: transport))
            client = SupabaseRecognitionClient(
                auth: auth, owner: DraftOwner(accountID: session.user.id, householdID: UUID()))
        }
    }
}

@MainActor
private final class RecognitionStorage: DraftStorage, ImageDraftStorage {
    let owner = DraftOwner(accountID: UUID(), householdID: UUID())
    var text: TextDraft?
    var image: ImageDraft?
    func load() async -> TextDraft? { text }
    func save(_ draft: TextDraft) async throws {
        try draft.validateStorage()
        text = draft
    }
    func clear() async {
        text = nil
        image = nil
    }
    func loadImageDraft() async -> ImageDraft? { image }
    func saveImageDraft(_ draft: ImageDraft) async throws {
        try draft.validateStorage()
        image = draft
    }
    func clearImageDraft() async { image = nil }
}

@MainActor
private final class RecognitionPhotoService: PhotoService {
    let owner: DraftOwner
    private var bytes: [UUID: Data] = [:]
    init(owner: DraftOwner) { self.owner = owner }
    func reserve(requestID: UUID) async throws -> PhotoReservation {
        let photoID = UUID()
        return PhotoReservation(
            photoId: photoID,
            objectKey: PhotoReservation.objectKey(
                householdID: owner.householdID, uploaderID: owner.accountID, photoID: photoID),
            expiresAt: Date().addingTimeInterval(3_600))
    }
    func upload(_ draft: ImageDraft, to reservation: PhotoReservation) async throws {
        bytes[reservation.photoId] = draft.jpegData
    }
    func complete(_ reservation: PhotoReservation) async throws {
        guard bytes[reservation.photoId] != nil else { throw PhotoFailure.uploadIncomplete }
    }
    func download(photoID: UUID) async throws -> Data { throw PhotoFailure.notFound }
    func discard(photoID: UUID) async throws { bytes[photoID] = nil }
}

@MainActor
private final class RecognitionRepository: InventoryRepository {
    let owner: DraftOwner
    var inputs: [CreateItemInput] = []
    init(owner: DraftOwner) { self.owner = owner }
    func create(_ input: CreateItemInput) async throws -> Item {
        inputs.append(input)
        return Item(
            id: UUID(), householdId: owner.householdID, name: input.fields.name,
            description: input.fields.description, brand: input.fields.brand, model: input.fields.model,
            purchasedOn: input.fields.purchasedOn, photoId: input.photoId,
            createdAt: Date(), updatedAt: Date(), version: 1,
            quantity: input.fields.quantity, restockLimit: input.fields.restockLimit)
    }
    func search(_ query: ItemQuery) async throws -> ItemPage { .init(data: [], nextOffset: nil) }
    func get(id: UUID) async throws -> Item { throw InventoryFailure.notFound }
    func update(_ input: UpdateItemInput) async throws -> Item { throw InventoryFailure.notFound }
    func delete(id: UUID, expectedVersion: Int64) async throws {}
    func removePhoto(itemID: UUID, expectedVersion: Int64) async throws -> Item {
        throw InventoryFailure.notFound
    }
}

@MainActor
private final class ControlledRecognitionClient: RecognitionClient {
    let owner: DraftOwner
    let source = RecognitionSource.provider
    var result: Result<RecognitionResult, any Error> = .failure(RecognitionFailure.unavailable)
    var hold = false
    var calls: [(photoID: UUID, requestID: UUID)] = []
    private var pending: CheckedContinuation<RecognitionResult, any Error>?
    init(owner: DraftOwner) { self.owner = owner }
    func recognize(photoID: UUID, requestID: UUID) async throws -> RecognitionResult {
        calls.append((photoID, requestID))
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try result.get()
    }
    func finish(_ result: Result<RecognitionResult, any Error>) {
        pending?.resume(with: result)
        pending = nil
    }
}

private struct RecognitionInputFixture: Decodable {
    let photoId: UUID
    let requestId: UUID
}

private nonisolated func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private final class RecognitionURLProtocol: URLProtocol, @unchecked Sendable {
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
                    headerFields: ["Content-Type": "application/json"]
                )
            else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
