import Foundation
import Testing

@testable import HouseKeeping

@MainActor
struct PhotoUploadStateTests {
    @Test func lostUploadResponseRecoversAfterRelaunchWithoutUploadingTwice() async throws {
        let f = try await Fixture()
        f.service.loseUploadResponse = true
        let first = PhotoImportModel(storage: f.storage, preparation: PhotoPreparation(), service: f.service)
        await first.restore()
        #expect(await first.uploadForSave() == nil)
        #expect(first.uploadFailure == .unavailable)
        let persisted = try #require(await f.storage.loadImageDraft())
        #expect(persisted.jpegData == f.image.jpegData)
        let reservation = try #require(persisted.upload?.reservation)
        #expect(persisted.upload?.isReady == false)
        #expect(f.service.uploadCount == 1)
        #expect(await first.close(discard: false))

        let relaunched = PhotoImportModel(storage: f.storage, preparation: PhotoPreparation(), service: f.service)
        await relaunched.restore()
        #expect(await relaunched.uploadForSave() == reservation.photoId)
        #expect(relaunched.uploadFailure == nil && relaunched.uploadStage == nil)
        #expect(f.service.uploadCount == 1 && f.service.requestIDs.count == 1)
        #expect(await f.storage.loadImageDraft()?.upload?.isReady == true)
    }

    @Test func expiredReservationIsReplacedOnlyAfterPersistingANewRequestIdentity() async throws {
        let f = try await Fixture()
        let oldRequest = UUID()
        var expired = f.image
        let oldPhotoID = UUID()
        expired.upload = PhotoUploadState(
            requestId: oldRequest,
            reservation: .init(
                photoId: oldPhotoID,
                objectKey: PhotoReservation.objectKey(
                    householdID: f.storage.owner.householdID,
                    uploaderID: f.storage.owner.accountID, photoID: oldPhotoID), expiresAt: .distantPast), isReady: true
        )
        try await f.storage.saveImageDraft(expired)
        let model = PhotoImportModel(storage: f.storage, preparation: PhotoPreparation(), service: f.service)
        await model.restore()
        let newPhotoID = try #require(await model.uploadForSave())
        #expect(newPhotoID != oldPhotoID)
        #expect(f.service.requestIDs.count == 1 && f.service.requestIDs.first != oldRequest)
        #expect(model.draft?.jpegData == f.image.jpegData)
        #expect(f.service.uploadCount == 1)
    }

    @Test func checkpointFailurePreventsNetworkAndAllowsExplicitRetry() async throws {
        let f = try await Fixture()
        await f.storage.setFailWrites(true)
        let model = PhotoImportModel(storage: f.storage, preparation: PhotoPreparation(), service: f.service)
        await model.restore()
        #expect(await model.uploadForSave() == nil)
        #expect(model.uploadFailure == .protectedStorage)
        #expect(f.service.requestIDs.isEmpty && f.service.uploadCount == 0)
        #expect(model.draft == f.image)
        await f.storage.setFailWrites(false)
        #expect(await model.uploadForSave() != nil)
        #expect(model.uploadFailure == nil)
    }

    @Test func reservationTimeoutReplaysThePersistedRequestID() async throws {
        let f = try await Fixture()
        f.service.loseReservationResponse = true
        let model = PhotoImportModel(storage: f.storage, preparation: PhotoPreparation(), service: f.service)
        await model.restore()
        #expect(await model.uploadForSave() == nil)
        let requestID = try #require(await f.storage.loadImageDraft()?.upload?.requestId)
        #expect(await model.uploadForSave() != nil)
        #expect(f.service.requestIDs == [requestID, requestID])
        #expect(f.service.reservations.count == 1)
    }

    @Test func closeDrainsPendingUploadAndLateWorkCannotRecreateDiscardedBytes() async throws {
        let f = try await Fixture()
        f.service.holdUpload = true
        let model = PhotoImportModel(storage: f.storage, preparation: PhotoPreparation(), service: f.service)
        await model.restore()
        let upload = Task { await model.uploadForSave() }
        for _ in 0..<1000 {
            if f.service.pendingUpload != nil { break }
            await Task.yield()
        }
        #expect(model.uploadStage == .uploading)
        let closing = Task { await model.close(discard: true) }
        for _ in 0..<1000 {
            if model.isClosing { break }
            await Task.yield()
        }
        #expect(model.isClosing)
        f.service.pendingUpload?.resume()
        f.service.pendingUpload = nil
        #expect(await upload.value == nil)
        #expect(await closing.value)
        #expect(await f.storage.loadImageDraft() == nil)
        #expect(model.draft == nil && !model.isActive)
        #expect(await model.uploadForSave() == nil)
    }

    @Test func serverExpiryAfterLostReservationReplyAllowsAFreshExplicitRetry() async throws {
        let f = try await Fixture()
        f.service.loseReservationResponse = true
        let model = PhotoImportModel(storage: f.storage, preparation: PhotoPreparation(), service: f.service)
        await model.restore()
        #expect(await model.uploadForSave() == nil)
        let expiredRequest = try #require(model.draft?.upload?.requestId)
        f.service.expiredRequests.insert(expiredRequest)
        #expect(await model.uploadForSave() == nil)
        #expect(model.uploadFailure == .expired)
        #expect(await f.storage.loadImageDraft()?.upload == nil)
        #expect(await model.uploadForSave() != nil)
        #expect(f.service.requestIDs.last != expiredRequest)
        #expect(model.draft?.jpegData == f.image.jpegData)
    }

    private struct Fixture {
        let image: ImageDraft
        let storage: UploadDraftStorage
        let service: ControlledPhotoService

        @MainActor init() async throws {
            let owner = DraftOwner(accountID: UUID(), householdID: UUID())
            image = ImageDraft(
                owner: owner,
                prepared: try await PhotoPreparation().prepare(
                    photoFixtureJPEG(width: 32, height: 24)))
            storage = UploadDraftStorage(owner: owner, value: image)
            service = ControlledPhotoService(storage: storage)
        }
    }
}

private actor UploadDraftStorage: ImageDraftStorage {
    nonisolated let owner: DraftOwner
    private var value: ImageDraft?
    private var failWrites = false
    init(owner: DraftOwner, value: ImageDraft) {
        self.owner = owner
        self.value = value
    }
    func loadImageDraft() -> ImageDraft? { value }
    func saveImageDraft(_ draft: ImageDraft) throws {
        if failWrites { throw DraftStorageFailure.unavailable }
        try draft.validateStorage()
        value = draft
    }
    func clearImageDraft() { value = nil }
    func setFailWrites(_ value: Bool) { failWrites = value }
}

@MainActor
private final class ControlledPhotoService: PhotoService {
    let owner: DraftOwner
    let storage: UploadDraftStorage
    var requestIDs: [UUID] = []
    var reservations: [UUID: PhotoReservation] = [:]
    var bytes: [UUID: Data] = [:]
    var uploadCount = 0
    var loseUploadResponse = false
    var loseReservationResponse = false
    var expiredRequests: Set<UUID> = []
    var holdUpload = false
    var pendingUpload: CheckedContinuation<Void, Never>?

    init(storage: UploadDraftStorage) {
        self.storage = storage
        owner = storage.owner
    }
    func reserve(requestID: UUID) async throws -> PhotoReservation {
        #expect(await storage.loadImageDraft()?.upload?.requestId == requestID)
        requestIDs.append(requestID)
        if expiredRequests.contains(requestID) { throw PhotoFailure.expired }
        let photoID = UUID()
        let reservation =
            reservations[requestID]
            ?? PhotoReservation(
                photoId: photoID,
                objectKey: PhotoReservation.objectKey(
                    householdID: owner.householdID, uploaderID: owner.accountID, photoID: photoID),
                expiresAt: Date().addingTimeInterval(3600))
        reservations[requestID] = reservation
        if loseReservationResponse {
            loseReservationResponse = false
            throw PhotoFailure.unavailable
        }
        return reservation
    }
    func upload(_ draft: ImageDraft, to reservation: PhotoReservation) async throws {
        #expect(await storage.loadImageDraft()?.upload?.reservation == reservation)
        uploadCount += 1
        if holdUpload { await withCheckedContinuation { pendingUpload = $0 } }
        bytes[reservation.photoId] = draft.jpegData
        if loseUploadResponse {
            loseUploadResponse = false
            throw PhotoFailure.unavailable
        }
    }
    func complete(_ reservation: PhotoReservation) async throws {
        if bytes[reservation.photoId] == nil { throw PhotoFailure.uploadIncomplete }
    }
    func download(photoID: UUID) async throws -> Data {
        guard let data = bytes[photoID] else { throw PhotoFailure.notFound }
        return data
    }
    func discard(photoID: UUID) async throws { bytes[photoID] = nil }
}
