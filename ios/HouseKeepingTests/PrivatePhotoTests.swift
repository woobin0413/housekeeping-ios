import Foundation
import Testing

@testable import HouseKeeping

@MainActor
struct PrivatePhotoTests {
    @Test func thumbnailsUseSmallerDecodeAndReleaseWithoutClearingDetail() async throws {
        let (store, service, item) = try await thumbnailFixture()
        let model = PrivatePhotoModel()
        await store.loadDetail(id: item.id)
        await store.loadThumbnail(for: item, into: model)
        #expect(model.image?.width == 192 && model.image?.height == 96)
        #expect(store.detailPhoto.image?.width == 1024)
        let cancelled = Task { await store.loadThumbnail(for: item, into: model) }
        cancelled.cancel()
        await cancelled.value
        #expect(model.image?.width == 192)
        store.releaseThumbnail(model)
        #expect(model.image == nil && store.detailPhoto.image != nil)
        let textOnly = try #require(store.items.first(where: { $0.photoId == nil }))
        let count = service.downloadCount
        await store.loadThumbnail(for: textOnly, into: model)
        #expect(service.downloadCount == count && model.image == nil)
    }

    @Test(arguments: ["release", "refresh", "retire", "deactivate"])
    func thumbnailInvalidationRejectsLatePrivateBytes(action: String) async throws {
        let (store, service, item) = try await thumbnailFixture()
        let model = PrivatePhotoModel()
        service.hold = true
        let loading = Task { await store.loadThumbnail(for: item, into: model) }
        for _ in 0..<1000 {
            if service.pending != nil { break }
            await Task.yield()
        }
        #expect(service.pending != nil && model.isLoading)
        switch action {
        case "release": store.releaseThumbnail(model)
        case "refresh": await store.refresh()
        case "retire": #expect(await store.retire())
        default: #expect(await store.deactivate(confirmedDiscard: true))
        }
        service.error = .forbidden
        service.pending?.resume()
        await loading.value
        #expect(model.image == nil && model.failure == nil && !model.isLoading)
        #expect(store.accessFailure == nil)
    }

    @Test func thumbnailAccessDenialClearsEveryDisplayedImage() async throws {
        let (store, service, item) = try await thumbnailFixture()
        let first = PrivatePhotoModel()
        let second = PrivatePhotoModel()
        await store.loadDetail(id: item.id)
        await store.loadThumbnail(for: item, into: first)
        #expect(first.image != nil)
        service.error = .forbidden
        await store.loadThumbnail(for: item, into: second)
        #expect(store.accessFailure == .forbidden && store.items.isEmpty)
        #expect(first.image == nil && second.image == nil && store.detailPhoto.image == nil)
    }

    private func thumbnailFixture() async throws -> (InventoryStore, DisplayPhotoService, Item) {
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let database = PreviewInventoryDatabase()
        let repository = PreviewInventoryRepository(householdID: owner.householdID, database: database)
        let writer = InventoryStore(
            repository: repository, draftStorage: PreviewDraftStorage(owner: owner),
            photoService: PreviewPhotoService(owner: owner, database: database))
        await writer.drafts.restore()
        await writer.photoDraft?.restore()
        #expect(writer.beginDraft())
        #expect(writer.drafts.edit(.init(name: "Thumbnail fixture")))
        let bytes = try photoFixtureJPEG(width: 2048, height: 1024)
        await writer.photoDraft?.importData(bytes)
        let item = try #require(await writer.saveDraft())
        _ = try #require(item.photoId)
        let service = DisplayPhotoService(owner: owner)
        service.bytes = bytes
        let store = InventoryStore(
            repository: repository, draftStorage: PreviewDraftStorage(owner: owner), photoService: service)
        await store.drafts.restore()
        await store.refresh()
        return (store, service, item)
    }

    @Test func validDownloadIsDecodedAndClearedWithTheSession() async throws {
        let service = DisplayPhotoService()
        service.bytes = try photoFixtureJPEG(width: 2048, height: 1024)
        let model = PrivatePhotoModel()
        await model.load(photoID: UUID(), service: service)
        #expect(model.image?.width == 1024 && model.image?.height == 512)
        #expect(!model.isLoading && model.failure == nil)
        model.clear()
        #expect(model.image == nil && model.failure == nil)
    }

    @Test func lateDownloadCannotRestoreClearedPrivateImage() async throws {
        let service = DisplayPhotoService()
        service.bytes = try photoFixtureJPEG(width: 32, height: 24)
        service.hold = true
        let model = PrivatePhotoModel()
        let loading = Task { await model.load(photoID: UUID(), service: service) }
        for _ in 0..<1000 {
            if service.pending != nil { break }
            await Task.yield()
        }
        #expect(model.isLoading && service.pending != nil)
        model.clear()
        service.pending?.resume()
        await loading.value
        #expect(model.image == nil && model.failure == nil && !model.isLoading)
    }

    @Test func failureAndMalformedDataNeverSubstituteSampleArtwork() async throws {
        let service = DisplayPhotoService()
        let model = PrivatePhotoModel()
        service.error = .forbidden
        await model.load(photoID: UUID(), service: service)
        #expect(model.image == nil && model.failure == .forbidden)
        service.error = nil
        service.bytes = Data("not an image".utf8)
        await model.load(photoID: UUID(), service: service)
        #expect(model.image == nil && model.failure == .invalidResponse)
        service.bytes = try photoFixtureJPEG(width: 64, height: 32)
        await model.load(photoID: UUID(), service: service)
        #expect(model.image != nil && model.failure == nil)
    }

    @Test func coordinatedPhotoAppearsForOtherSpouseAndClearsOnRetirement() async throws {
        let householdID = UUID()
        let a = DraftOwner(accountID: UUID(), householdID: householdID)
        let b = DraftOwner(accountID: UUID(), householdID: householdID)
        let database = PreviewInventoryDatabase()
        let storeA = InventoryStore(
            repository: PreviewInventoryRepository(householdID: householdID, database: database),
            draftStorage: PreviewDraftStorage(owner: a),
            photoService: PreviewPhotoService(owner: a, database: database))
        await storeA.drafts.restore()
        await storeA.photoDraft?.restore()
        #expect(storeA.beginDraft())
        #expect(storeA.drafts.edit(.init(name: "Photographed purchase")))
        await storeA.photoDraft?.importData(try photoFixtureJPEG(width: 64, height: 32))
        let saved = try #require(await storeA.saveDraft())
        let storeB = InventoryStore(
            repository: PreviewInventoryRepository(householdID: householdID, database: database),
            draftStorage: PreviewDraftStorage(owner: b),
            photoService: PreviewPhotoService(owner: b, database: database))
        await storeB.loadDetail(id: saved.id)
        #expect(storeB.detailPhoto.image?.width == 64)
        await storeB.refresh()
        let thumbnail = PrivatePhotoModel()
        await storeB.loadThumbnail(for: saved, into: thumbnail)
        #expect(thumbnail.image?.width == 64)
        #expect(!(await storeB.removePhoto(from: saved, confirmed: false)))
        #expect(storeB.detailPhoto.image != nil)
        #expect(await storeB.retire())
        #expect(storeB.detailPhoto.image == nil && storeB.detail == nil)
        #expect(thumbnail.image == nil)
        #expect(storeA.photoDraft?.draft == nil)
        let remover = InventoryStore(
            repository: PreviewInventoryRepository(householdID: householdID, database: database),
            draftStorage: PreviewDraftStorage(owner: b),
            photoService: PreviewPhotoService(owner: b, database: database))
        await remover.drafts.restore()
        await remover.photoDraft?.restore()
        await remover.loadDetail(id: saved.id)
        #expect(await remover.removePhoto(from: saved, confirmed: true))
        #expect(remover.detail?.photoId == nil && remover.detailPhoto.image == nil)
        #expect(remover.detail?.fields == saved.fields && remover.detail?.version == saved.version + 1)
        await storeA.loadDetail(id: saved.id)
        #expect(storeA.detail?.photoId == nil && storeA.detailPhoto.image == nil)
    }

    @Test func photoAccessFailureHidesSharedDataAndOrphanPhotoCannotBecomeAnEdit() async throws {
        let storage = PreviewDraftStorage(owner: .init(accountID: UUID(), householdID: UUID()))
        let service = DisplayPhotoService(owner: storage.owner)
        let repository = PreviewInventoryRepository(householdID: storage.owner.householdID)
        let store = InventoryStore(repository: repository, draftStorage: storage, photoService: service)
        await store.drafts.restore()
        await store.photoDraft?.restore()
        await store.refresh()
        let item = try #require(store.items.first)
        await store.photoDraft?.importData(try photoFixtureJPEG(width: 32, height: 24))
        #expect(!store.beginDraft(item: item))
        #expect(store.beginDraft())
        #expect(store.drafts.edit(.init(name: "Private draft")))
        service.error = .forbidden
        #expect(await store.saveDraft() == nil)
        #expect(store.accessFailure == .forbidden && store.items.isEmpty)
        #expect(store.photoDraft?.draft != nil && store.drafts.draft != nil)
    }
}

@MainActor
private final class DisplayPhotoService: PhotoService {
    let owner: DraftOwner
    var bytes = Data()
    var error: PhotoFailure?
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    var downloadCount = 0
    init(owner: DraftOwner = .init(accountID: UUID(), householdID: UUID())) { self.owner = owner }
    func download(photoID: UUID) async throws -> Data {
        downloadCount += 1
        if hold { await withCheckedContinuation { pending = $0 } }
        if let error { throw error }
        return bytes
    }
    func reserve(requestID: UUID) async throws -> PhotoReservation { throw error ?? PhotoFailure.unavailable }
    func upload(_ draft: ImageDraft, to reservation: PhotoReservation) async throws {}
    func complete(_ reservation: PhotoReservation) async throws {}
    func discard(photoID: UUID) async throws {}
}
