import Foundation
import Testing

@testable import HouseKeeping

/// Explicit opt-in only. The runner owns disposable local accounts and deletes the fixture file.
@MainActor
struct LocalSupabaseTests {
    nonisolated private static var fixturePath: String {
        ProcessInfo.processInfo.environment["HK_LOCAL_AUTH_FIXTURE", default: ""]
    }

    @Test(.enabled(if: fixturePath.hasPrefix("/tmp/housekeeping-ios-auth.")))
    func bothSpousesUseRealSDKAndProtectedSession() async throws {
        let fixtureURL = URL(fileURLWithPath: Self.fixturePath)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        guard fixture.url == "http://127.0.0.1:55321",
            fixture.a.email.hasSuffix("@example.invalid"), fixture.b.email.hasSuffix("@example.invalid")
        else {
            throw FixtureFailure.unsafeTarget
        }
        let configuration = try AppConfiguration(
            values: [
                "HK_SUPABASE_URL": fixture.url,
                "HK_SUPABASE_PUBLISHABLE_KEY": fixture.publishableKey,
            ], allowLocalHTTP: true)
        let namespaceA = "com.housekeeping.localtest." + fixture.runID.uuidString + ".a"
        let namespaceB = "com.housekeeping.localtest." + fixture.runID.uuidString + ".b"
        let storageA = KeychainSessionStorage(projectURL: configuration.url, bundleID: namespaceA)
        let storageB = KeychainSessionStorage(projectURL: configuration.url, bundleID: namespaceB)
        defer {
            for storage in [storageA, storageB] {
                do {
                    try storage.remove(key: "session")
                    #expect(try storage.retrieve(key: "session") == nil)
                } catch {
                    Issue.record("Disposable local session Keychain cleanup failed")
                }
            }
        }
        let a = SupabaseAuthService(configuration: configuration, bundleID: namespaceA)
        let b = SupabaseAuthService(configuration: configuration, bundleID: namespaceB)
        #expect(try await a.signIn(email: fixture.a.email, password: fixture.a.password).id == fixture.a.id)
        #expect(try await b.signIn(email: fixture.b.email, password: fixture.b.password).id == fixture.b.id)
        #expect(try await a.household().householdId == fixture.household)
        #expect(try await b.household().householdId == fixture.household)
        let restored = SupabaseAuthService(configuration: configuration, bundleID: namespaceA)
        #expect(try await restored.restore()?.id == fixture.a.id)
        try await verifySharedInventory(a: a, restored: restored, b: b, fixture: fixture)
        try await verifyPrivatePhotos(a: restored, b: b, fixture: fixture)
        #expect(try await restored.signOut() == .complete)
        #expect(try await restored.restore() == nil)
        #expect(try await b.restore()?.id == fixture.b.id)
        #expect(try await b.signOut() == .complete)
        #expect(try storageA.retrieve(key: "session") == nil)
        #expect(try storageB.retrieve(key: "session") == nil)
    }

    private func verifyPrivatePhotos(a: SupabaseAuthService, b: SupabaseAuthService, fixture: Fixture) async throws {
        let ownerA = DraftOwner(accountID: fixture.a.id, householdID: fixture.household)
        let ownerB = DraftOwner(accountID: fixture.b.id, householdID: fixture.household)
        let photosA = SupabasePhotoService(auth: a, owner: ownerA)
        let photosB = SupabasePhotoService(auth: b, owner: ownerB)
        let repositoryA = SupabaseInventoryRepository(
            auth: a, accountID: ownerA.accountID, householdID: fixture.household)
        let repositoryB = SupabaseInventoryRepository(
            auth: b, accountID: ownerB.accountID, householdID: fixture.household)
        var step = "reservation"
        do {
            for (uploader, reader, repository) in [(photosA, photosB, repositoryA), (photosB, photosA, repositoryB)] {
                let prepared = try await PhotoPreparation().prepare(
                    photoFixtureJPEG(width: 64, height: 32, metadata: true))
                let draft = ImageDraft(owner: uploader.owner, prepared: prepared)
                let requestID = UUID()
                let reservation = try await uploader.reserve(requestID: requestID)
                #expect(try await uploader.reserve(requestID: requestID) == reservation)
                step = "upload"
                try await uploader.upload(draft, to: reservation)
                await #expect(throws: PhotoFailure.notFound) {
                    try await reader.download(photoID: reservation.photoId)
                }
                step = "completion"
                try await uploader.complete(reservation)
                try await uploader.complete(reservation)
                step = "attachment"
                let item = try await repository.create(
                    .init(
                        householdId: fixture.household, requestId: UUID(),
                        fields: .init(name: "Synthetic photo purchase"),
                        photoId: reservation.photoId))
                #expect(item.photoId == reservation.photoId)
                step = "authenticated download"
                #expect(try await uploader.download(photoID: reservation.photoId) == prepared.jpegData)
                #expect(try await reader.download(photoID: reservation.photoId) == prepared.jpegData)
                // Reconstruct the adapter as on session restoration: no cached object or URL is required.
                let reloaded = SupabasePhotoService(auth: uploader.owner == ownerA ? a : b, owner: uploader.owner)
                #expect(try await reloaded.download(photoID: reservation.photoId) == prepared.jpegData)
                step = "deletion"
                try await repository.delete(id: item.id, expectedVersion: item.version)
                await #expect(throws: PhotoFailure.notFound) { try await reader.download(photoID: reservation.photoId) }
            }
            step = "coordinated save"
            let root = FileManager.default.temporaryDirectory.appending(
                path: "housekeeping-photo-coordination-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let disk = LocalDraftStore(projectURL: URL(string: fixture.url)!, owner: ownerA, rootDirectory: root)
            let coordinated = InventoryStore(
                repository: repositoryA, draftStorage: disk, photoService: photosA,
                recognitionClient: SupabaseRecognitionClient(auth: a, owner: ownerA))
            await coordinated.drafts.restore()
            await coordinated.photoDraft?.restore()
            #expect(coordinated.beginDraft())
            #expect(coordinated.drafts.edit(.init(name: "Coordinated photo purchase")))
            await coordinated.photoDraft?.importData(try photoFixtureJPEG(width: 64, height: 32))
            let preparedBytes = try #require(coordinated.photoDraft?.draft?.jpegData)
            step = "recognition fallback"
            #expect(await coordinated.requestRecognition() == nil)
            #expect(coordinated.recognitionState == .failed(.unavailable))
            #expect(coordinated.drafts.draft?.fields.name == "Coordinated photo purchase")
            step = "manual save after recognition fallback"
            let saved = try #require(await coordinated.saveDraft())
            let photoID = try #require(saved.photoId)
            #expect(coordinated.photoDraft?.draft == nil && coordinated.drafts.draft == nil)
            #expect(try await disk.loadImageDraft() == nil)
            #expect(try await disk.load() == nil)
            #expect(try await photosB.download(photoID: photoID) == preparedBytes)
            let reader = InventoryStore(
                repository: repositoryB,
                draftStorage: LocalDraftStore(
                    projectURL: URL(string: fixture.url)!, owner: ownerB, rootDirectory: root),
                photoService: photosB)
            await reader.loadDetail(id: saved.id)
            #expect(reader.detailPhoto.image?.width == 64 && reader.detailPhoto.image?.height == 32)
            await reader.refresh()
            let thumbnail = PrivatePhotoModel()
            await reader.loadThumbnail(for: saved, into: thumbnail)
            #expect(thumbnail.image?.width == 64 && thumbnail.image?.height == 32)
            let removed = try await repositoryB.removePhoto(itemID: saved.id, expectedVersion: saved.version)
            #expect(removed.photoId == nil && removed.fields == saved.fields && removed.version == saved.version + 1)
            #expect(try await repositoryA.get(id: saved.id).photoId == nil)
            await #expect(throws: PhotoFailure.notFound) { try await photosA.download(photoID: photoID) }
            let removalReplay = try await repositoryB.removePhoto(itemID: saved.id, expectedVersion: removed.version)
            #expect(removalReplay == removed)
            #expect(await reader.retire())
            #expect(reader.detailPhoto.image == nil)
            #expect(thumbnail.image == nil)
            try await repositoryB.delete(id: saved.id, expectedVersion: removed.version)
            step = "discard"
            let abandoned = try await photosA.reserve(requestID: UUID())
            try await photosA.discard(photoID: abandoned.photoId)
        } catch {
            Issue.record("Local private photo check failed during \(step). Response details suppressed.")
            throw error
        }
    }

    private func verifySharedInventory(
        a: SupabaseAuthService, restored: SupabaseAuthService, b: SupabaseAuthService, fixture: Fixture
    ) async throws {
        let first = SupabaseInventoryRepository(auth: a, accountID: fixture.a.id, householdID: fixture.household)
        let reloaded = SupabaseInventoryRepository(
            auth: restored, accountID: fixture.a.id, householdID: fixture.household)
        let second = SupabaseInventoryRepository(auth: b, accountID: fixture.b.id, householdID: fixture.household)
        let inputA = CreateItemInput(
            householdId: fixture.household, requestId: UUID(),
            fields: .init(
                name: "\t Shared kettle\n", description: "Black kitchen appliance",
                purchasedOn: try PurchaseDate("2024-02-29")))
        let itemA = try await first.create(inputA)
        #expect(itemA.name == "Shared kettle")
        #expect(itemA.version == 1 && itemA.photoId == nil)
        #expect(try await reloaded.get(id: itemA.id) == itemA)
        #expect(try await second.get(id: itemA.id) == itemA)
        #expect(try await first.create(inputA).id == itemA.id)

        let itemB = try await second.create(
            .init(
                householdId: fixture.household, requestId: UUID(),
                fields: .init(name: "Shared lamp", description: "Reading corner")))
        #expect(try await first.get(id: itemB.id) == itemB)
        let page = try await first.search(.init(householdId: fixture.household, query: "SHARED", limit: 1))
        let nextOffset = try #require(page.nextOffset)
        let next = try await second.search(
            .init(householdId: fixture.household, query: "SHARED", limit: 1, offset: nextOffset))
        #expect(next.nextOffset == nil)
        #expect(Set((page.data + next.data).map(\.id)) == [itemA.id, itemB.id])
        #expect(
            try await second.search(.init(householdId: fixture.household, query: "black KITCHEN")).data.map(\.id) == [
                itemA.id
            ])

        let editedA = try await second.update(
            .init(id: itemA.id, expectedVersion: itemA.version, fields: .init(description: .set(nil))))
        #expect(editedA.version == 2 && editedA.description == nil)
        #expect(try await first.get(id: itemA.id) == editedA)
        await #expect(throws: InventoryFailure.conflict) {
            try await first.update(
                .init(id: itemA.id, expectedVersion: itemA.version, fields: .init(name: "Stale edit")))
        }
        #expect(try await first.create(inputA) == editedA)
        await #expect(throws: InventoryFailure.conflict) {
            try await first.create(
                .init(householdId: fixture.household, requestId: inputA.requestId, fields: .init(name: "Changed retry"))
            )
        }
        let editedB = try await first.update(
            .init(id: itemB.id, expectedVersion: itemB.version, fields: .init(brand: .set("Synthetic brand"))))
        #expect(try await second.get(id: itemB.id) == editedB)
        try await second.delete(id: itemA.id, expectedVersion: editedA.version)
        try await second.delete(id: itemA.id, expectedVersion: itemA.version)
        await #expect(throws: InventoryFailure.notFound) { try await first.get(id: itemA.id) }
        await #expect(throws: InventoryFailure.conflict) { try await first.create(inputA) }
        try await first.delete(id: itemB.id, expectedVersion: editedB.version)
        #expect(try await second.search(.init(householdId: fixture.household, query: "")).data.isEmpty)
        try await verifyConnectedStoreLifecycle(first: first, reloaded: reloaded, second: second, fixture: fixture)
    }

    private func verifyConnectedStoreLifecycle(
        first: SupabaseInventoryRepository, reloaded: SupabaseInventoryRepository,
        second: SupabaseInventoryRepository, fixture: Fixture
    ) async throws {
        let ownerA = DraftOwner(accountID: fixture.a.id, householdID: fixture.household)
        let ownerB = DraftOwner(accountID: fixture.b.id, householdID: fixture.household)
        let diskA = LocalSDKDraftStorage(owner: ownerA)
        let storeA = InventoryStore(repository: first, draftStorage: diskA, debounce: .zero)
        await storeA.drafts.restore()
        #expect(storeA.beginDraft())
        #expect(
            storeA.drafts.edit(
                .init(name: "Connected store \(fixture.runID)", description: "Created through durable draft state")))
        let created = try #require(await storeA.saveDraft())

        let storeB = InventoryStore(
            repository: second, draftStorage: LocalSDKDraftStorage(owner: ownerB), debounce: .zero)
        await storeB.drafts.restore()
        await storeB.refresh()
        #expect(storeB.items.contains(created))
        #expect(storeB.beginDraft(item: created))
        var changed = created.fields
        changed.description = "Edited by the second household member"
        #expect(storeB.drafts.edit(changed))
        let edited = try #require(await storeB.saveDraft())
        #expect(edited.version == created.version + 1)

        let relaunched = InventoryStore(repository: reloaded, draftStorage: diskA, debounce: .zero)
        await relaunched.drafts.restore()
        await relaunched.refresh()
        #expect(relaunched.items.first(where: { $0.id == created.id }) == edited)
        #expect(await relaunched.delete(edited, confirmed: true))
        await storeB.refresh()
        #expect(!storeB.items.contains(where: { $0.id == created.id }))
    }

    private enum FixtureFailure: Error { case unsafeTarget }
    private struct Fixture: Decodable {
        let runID: UUID
        let url: String
        let publishableKey: String
        let household: UUID
        let a: User
        let b: User
        struct User: Decodable {
            let id: UUID
            let email: String
            let password: String
        }
    }
}

private actor LocalSDKDraftStorage: DraftStorage {
    nonisolated let owner: DraftOwner
    private var value: TextDraft?
    init(owner: DraftOwner) { self.owner = owner }
    func load() -> TextDraft? { value }
    func save(_ draft: TextDraft) { value = draft }
    func clear() { value = nil }
}
