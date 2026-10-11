import Foundation
import Testing

@testable import HouseKeeping

@MainActor
struct SharedPhotoStateTests {
    @Test func successfulPhotoSaveAttachesAndClearsBothLocalDrafts() async throws {
        let f = try await Fixture()
        let item = try #require(await f.store.saveDraft())
        #expect(item.photoId != nil)
        #expect(f.storage.text == nil && f.storage.image == nil)
        #expect(f.store.photoDraft?.draft == nil)
        #expect(f.store.items == [item])
        #expect(f.photos.uploads == 1)
    }

    @Test func uncertainSaveReplaysExpiredPhotoWithoutStartingAnotherUpload() async throws {
        let f = try await Fixture()
        f.repository.loseCreateResponse = true
        #expect(await f.store.saveDraft() == nil)
        let original = try #require(f.repository.inputs.first)
        #expect(f.storage.text?.phase == .submitting)
        #expect(await f.store.retire())
        let reservation = try #require(f.storage.image?.upload?.reservation)
        f.storage.image?.upload?.reservation = .init(
            photoId: reservation.photoId,
            objectKey: reservation.objectKey, expiresAt: .distantPast)
        let restored = InventoryStore(repository: f.repository, draftStorage: f.storage, photoService: f.photos)
        await restored.drafts.restore()
        #expect(await restored.saveDraft() != nil)
        #expect(f.repository.inputs == [original, original])
        #expect(f.photos.uploads == 1 && f.photos.reservations == 1)
        #expect(f.storage.text == nil && f.storage.image == nil)
    }

    @Test func definiteReadinessRejectionPreservesDraftAndRenewsAfterReconstruction() async throws {
        let f = try await Fixture()
        f.repository.rejectPhoto = true
        #expect(await f.store.saveDraft() == nil)
        let rejected = try #require(f.repository.inputs.first)
        #expect(f.storage.text?.rejectedPhotoId == rejected.photoId)
        #expect(f.storage.text?.phase == .editing)
        #expect(f.storage.image != nil)
        #expect(await f.store.retire())
        let restored = InventoryStore(repository: f.repository, draftStorage: f.storage, photoService: f.photos)
        await restored.drafts.restore()
        #expect(await restored.saveDraft() != nil)
        let retry = try #require(f.repository.inputs.last)
        #expect(retry.requestId == rejected.requestId && retry.fields == rejected.fields)
        #expect(retry.photoId != rejected.photoId)
        #expect(f.photos.uploads == 2 && f.photos.reservations == 2)
    }

    @Test func signOutDuringUploadPreventsPurchaseCreationAndClearsLateCheckpoints() async throws {
        let f = try await Fixture()
        f.photos.holdUpload = true
        let saving = Task { await f.store.saveDraft() }
        for _ in 0..<1000 {
            if f.photos.pending != nil { break }
            await Task.yield()
        }
        #expect(f.store.isPreparingPhotoSave && f.photos.pending != nil)
        #expect(await f.store.saveDraft() == nil)
        let closing = Task { await f.store.deactivate(confirmedDiscard: true) }
        for _ in 0..<1000 {
            if f.store.photoDraft?.isClosing == true { break }
            await Task.yield()
        }
        #expect(f.store.photoDraft?.isClosing == true)
        f.photos.pending?.resume()
        f.photos.pending = nil
        #expect(await saving.value == nil)
        #expect(await closing.value)
        #expect(f.repository.inputs.isEmpty)
        #expect(f.storage.text == nil && f.storage.image == nil)
    }

    @Test func invalidPurchaseDoesNotUploadAndWrongSessionServiceIsRejected() async throws {
        let f = try await Fixture()
        #expect(f.store.drafts.edit(.init(name: "")))
        #expect(await f.store.saveDraft() == nil)
        #expect(f.photos.reservations == 0 && f.repository.inputs.isEmpty)
        let wrong = MemoryPhotoService(owner: .init(accountID: UUID(), householdID: UUID()))
        let isolated = InventoryStore(repository: f.repository, draftStorage: f.storage, photoService: wrong)
        #expect(isolated.photos == nil)
    }

    @Test func failedRejectedCheckpointResetSurvivesReconstruction() async throws {
        let f = try await Fixture()
        f.repository.rejectPhoto = true
        #expect(await f.store.saveDraft() == nil)
        let rejected = try #require(f.repository.inputs.first)
        f.storage.failImageWrites = true
        #expect(await f.store.saveDraft() == nil)
        #expect(f.storage.text?.rejectedPhotoId == rejected.photoId)
        #expect(f.repository.inputs.count == 1 && f.photos.uploads == 1)
        #expect(await f.store.retire())
        f.storage.failImageWrites = false
        let restored = InventoryStore(repository: f.repository, draftStorage: f.storage, photoService: f.photos)
        await restored.drafts.restore()
        #expect(await restored.saveDraft() != nil)
        #expect(f.repository.inputs.last?.photoId != rejected.photoId)
        #expect(f.repository.inputs.last?.requestId == rejected.requestId)
    }

    @Test func signOutDrainsRejectedCheckpointResetBeforeClearingFiles() async throws {
        let f = try await Fixture()
        f.repository.rejectPhoto = true
        #expect(await f.store.saveDraft() == nil)
        f.storage.holdImageWrite = true
        let saving = Task { await f.store.saveDraft() }
        for _ in 0..<1000 {
            if f.storage.pendingImageWrite != nil { break }
            await Task.yield()
        }
        #expect(f.storage.pendingImageWrite != nil)
        let closing = Task { await f.store.deactivate(confirmedDiscard: true) }
        for _ in 0..<1000 {
            if f.store.photoDraft?.isClosing == true { break }
            await Task.yield()
        }
        #expect(f.store.photoDraft?.isClosing == true)
        f.storage.pendingImageWrite?.resume()
        f.storage.pendingImageWrite = nil
        #expect(await saving.value == nil)
        #expect(await closing.value)
        #expect(f.repository.inputs.count == 1)
        #expect(f.storage.text == nil && f.storage.image == nil)
        #expect(f.store.photoDraft?.draft == nil)
    }

    private struct Fixture {
        let storage = SharedPhotoStorage()
        let repository: PhotoInventoryRepository
        let photos: MemoryPhotoService
        let store: InventoryStore
        @MainActor init() async throws {
            repository = PhotoInventoryRepository(owner: storage.owner)
            photos = MemoryPhotoService(owner: storage.owner)
            store = InventoryStore(repository: repository, draftStorage: storage, photoService: photos)
            await store.drafts.restore()
            await store.photoDraft?.restore()
            #expect(store.beginDraft())
            #expect(store.drafts.edit(.init(name: "Shared photo purchase")))
            await store.photoDraft?.importData(try photoFixtureJPEG(width: 32, height: 24))
        }
    }
}

@MainActor
private final class SharedPhotoStorage: DraftStorage, ImageDraftStorage {
    let owner = DraftOwner(accountID: UUID(), householdID: UUID())
    var text: TextDraft?
    var image: ImageDraft?
    var failImageWrites = false
    var holdImageWrite = false
    var pendingImageWrite: CheckedContinuation<Void, Never>?
    func load() async throws -> TextDraft? { text }
    func save(_ draft: TextDraft) async throws {
        try draft.validateStorage()
        text = draft
    }
    func clear() async throws {
        text = nil
        image = nil
    }
    func loadImageDraft() async throws -> ImageDraft? { image }
    func saveImageDraft(_ draft: ImageDraft) async throws {
        if failImageWrites { throw DraftStorageFailure.unavailable }
        if holdImageWrite { await withCheckedContinuation { pendingImageWrite = $0 } }
        try draft.validateStorage()
        image = draft
    }
    func clearImageDraft() async throws { image = nil }
}

@MainActor
private final class MemoryPhotoService: PhotoService {
    let owner: DraftOwner
    var uploads = 0
    var reservations = 0
    var uploaded: Set<UUID> = []
    var holdUpload = false
    var pending: CheckedContinuation<Void, Never>?
    init(owner: DraftOwner) { self.owner = owner }
    func reserve(requestID: UUID) async throws -> PhotoReservation {
        reservations += 1
        let id = UUID()
        return .init(
            photoId: id,
            objectKey: PhotoReservation.objectKey(
                householdID: owner.householdID,
                uploaderID: owner.accountID, photoID: id), expiresAt: Date().addingTimeInterval(3600))
    }
    func upload(_ draft: ImageDraft, to reservation: PhotoReservation) async throws {
        uploads += 1
        if holdUpload { await withCheckedContinuation { pending = $0 } }
        uploaded.insert(reservation.photoId)
    }
    func complete(_ reservation: PhotoReservation) async throws {
        if !uploaded.contains(reservation.photoId) { throw PhotoFailure.uploadIncomplete }
    }
    func download(photoID: UUID) async throws -> Data { throw PhotoFailure.notFound }
    func discard(photoID: UUID) async throws { uploaded.remove(photoID) }
}

@MainActor
private final class PhotoInventoryRepository: InventoryRepository {
    let owner: DraftOwner
    var inputs: [CreateItemInput] = []
    var item: Item?
    var loseCreateResponse = false
    var rejectPhoto = false
    init(owner: DraftOwner) { self.owner = owner }
    func create(_ input: CreateItemInput) async throws -> Item {
        inputs.append(input)
        if rejectPhoto {
            rejectPhoto = false
            throw InventoryFailure.photoNotReady
        }
        if item == nil {
            item = Item(
                id: UUID(), householdId: owner.householdID, name: input.fields.name,
                description: nil, brand: nil, model: nil, purchasedOn: nil, photoId: input.photoId,
                createdAt: Date(), updatedAt: Date(), version: 1)
        }
        if loseCreateResponse {
            loseCreateResponse = false
            throw InventoryFailure.unavailable
        }
        return try #require(item)
    }
    func search(_ query: ItemQuery) async throws -> ItemPage { .init(data: item.map { [$0] } ?? [], nextOffset: nil) }
    func get(id: UUID) async throws -> Item { try #require(item) }
    func update(_ input: UpdateItemInput) async throws -> Item { try #require(item) }
    func delete(id: UUID, expectedVersion: Int64) async throws { item = nil }
    func removePhoto(itemID: UUID, expectedVersion: Int64) async throws -> Item {
        throw InventoryFailure.unavailable
    }
}
