import Foundation
import Observation

@MainActor @Observable
final class InventoryStore {
    let drafts: InventoryDraftController
    let photoDraft: PhotoImportModel?
    let photos: (any PhotoService)?
    let recognitions: (any RecognitionClient)?
    let detailPhoto = PrivatePhotoModel()
    private(set) var thumbnailGeneration = UUID()
    @ObservationIgnored private var thumbnails: [ObjectIdentifier: (model: PrivatePhotoModel, request: UUID)] = [:]
    private(set) var isPreparingPhotoSave = false
    private(set) var isRemovingPhoto = false
    private(set) var query = ""
    private(set) var items: [Item] = []
    private(set) var nextOffset: Int?
    private(set) var isLoading = false
    private(set) var failure: InventoryFailure?
    private(set) var accessFailure: InventoryFailure?
    private(set) var lastUpdated: Date?
    private(set) var isActive = true
    private(set) var isDeactivating = false
    private(set) var detail: Item?
    private(set) var detailFailure: InventoryFailure?
    private(set) var isLoadingDetail = false
    private(set) var mutationFailure: InventoryFailure?
    private(set) var recognitionState = RecognitionFlowState.idle
    @ObservationIgnored private var detailGeneration = UUID()
    private let repository: any InventoryRepository
    private let householdID: UUID
    private let debounce: Duration
    @ObservationIgnored private var requestGeneration = UUID()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleGeneration = UUID()
    @ObservationIgnored private var recognitionGeneration = UUID()
    @ObservationIgnored private var recognitionTask: Task<RecognitionResult, Error>?
    @ObservationIgnored private var recognitionNeedsNewRequest = false

    init(
        repository: any InventoryRepository, draftStorage: any DraftStorage,
        photoService: (any PhotoService)? = nil, recognitionClient: (any RecognitionClient)? = nil,
        debounce: Duration = .milliseconds(250)
    ) {
        self.repository = repository
        let scopedPhotos = photoService?.owner == draftStorage.owner ? photoService : nil
        photos = scopedPhotos
        recognitions = scopedPhotos != nil && recognitionClient?.owner == draftStorage.owner ? recognitionClient : nil
        householdID = draftStorage.owner.householdID
        self.debounce = debounce
        drafts = InventoryDraftController(storage: draftStorage, repository: repository)
        photoDraft = (draftStorage as? any ImageDraftStorage).map {
            PhotoImportModel(storage: $0, preparation: PhotoPreparation(), service: scopedPhotos)
        }
    }

    func setQuery(_ value: String) {
        guard isActive, !isDeactivating, accessFailure == nil else { return }
        query = value
        let generation = resetSearch()
        searchTask = Task {
            do { try await Task.sleep(for: debounce) } catch { return }
            await fetch(offset: 0, generation: generation)
        }
    }

    func refresh() async {
        guard isActive, !isDeactivating, accessFailure == nil else { return }
        await fetch(offset: 0, generation: resetSearch())
    }

    func loadMore() async {
        guard isActive, !isDeactivating, accessFailure == nil, !isLoading, let nextOffset else { return }
        await fetch(offset: nextOffset, generation: requestGeneration)
    }

    @discardableResult
    func saveDraft() async -> Item? {
        guard isActive, !isDeactivating, accessFailure == nil, !isPreparingPhotoSave, !drafts.isSaving else {
            return nil
        }
        isPreparingPhotoSave = true
        defer { isPreparingPhotoSave = false }
        cancelRecognition(state: .manual)
        let generation = lifecycleGeneration
        await photoDraft?.restore()
        guard isActive, !isDeactivating, generation == lifecycleGeneration, accessFailure == nil,
            let current = drafts.draft
        else { return nil }
        var photoID: UUID?
        if current.phase == .editing {
            guard photoDraft?.hasRestored != false, photoDraft?.isBusy != true else { return nil }
            if let photoDraft, photoDraft.draft != nil {
                guard photos != nil, current.baseItem == nil else { return nil }
                do { try current.fields.validate() } catch {
                    mutationFailure = .validation
                    return nil
                }
                // A durable rejection flag also survives failure while resetting the image checkpoint.
                if current.rejectedPhotoId != nil {
                    guard await photoDraft.resetRejectedUpload(), await drafts.acknowledgePhotoReset() else {
                        return nil
                    }
                }
                photoID = await photoDraft.uploadForSave()
                guard isActive, !isDeactivating, generation == lifecycleGeneration else { return nil }
                guard photoID != nil else {
                    recordPhotoAccessFailure(photoDraft.uploadFailure)
                    return nil
                }
            } else if photoDraft?.blocksPurchaseSave == true {
                return nil
            }
        }
        guard isActive, !isDeactivating, generation == lifecycleGeneration else { return nil }
        let saved = await drafts.save(photoId: photoID)
        guard isActive, generation == lifecycleGeneration else { return nil }
        if let saved {
            photoDraft?.purchaseSaved()
            mutationFailure = nil
            if detail?.id == saved.id { detail = saved }
            await refresh()
        }
        if let error = drafts.saveFailure {
            mutationFailure = error
            if error == .unauthenticated || error == .forbidden { record(error) }
        }
        return saved
    }

    /// A row owns its model; the session retains it only until release or invalidation.
    func loadThumbnail(for item: Item, into model: PrivatePhotoModel) async {
        guard !Task.isCancelled else { return }
        releaseThumbnail(model)
        guard isActive, !isDeactivating, accessFailure == nil, !Task.isCancelled,
            item.householdId == householdID, let photoID = item.photoId, let photos,
            items.contains(where: { $0.id == item.id && $0.photoId == photoID })
        else { return }
        let key = ObjectIdentifier(model)
        let request = UUID()
        thumbnails[key] = (model, request)
        await model.load(photoID: photoID, service: photos, size: .thumbnail)
        guard thumbnails[key]?.request == request, isActive, !isDeactivating, !Task.isCancelled else { return }
        recordPhotoAccessFailure(model.failure)
    }

    func releaseThumbnail(_ model: PrivatePhotoModel) {
        thumbnails.removeValue(forKey: ObjectIdentifier(model))
        model.clear()
    }

    private func clearThumbnails() {
        for entry in thumbnails.values { entry.model.clear() }
        thumbnails.removeAll()
        thumbnailGeneration = UUID()
    }

    func loadDetail(id: UUID) async {
        guard isActive, !isDeactivating, accessFailure == nil else { return }
        let lifecycle = lifecycleGeneration
        let generation = UUID()
        detailGeneration = generation
        detail = nil
        detailPhoto.clear()
        detailFailure = nil
        isLoadingDetail = true
        defer { if generation == detailGeneration { isLoadingDetail = false } }
        do {
            let item = try await repository.get(id: id)
            guard isActive, lifecycle == lifecycleGeneration, generation == detailGeneration else { return }
            detail = item
            if let photoID = item.photoId, let photos {
                await detailPhoto.load(photoID: photoID, service: photos)
                guard isActive, lifecycle == lifecycleGeneration, generation == detailGeneration else { return }
                recordPhotoAccessFailure(detailPhoto.failure)
            }
        } catch {
            guard isActive, lifecycle == lifecycleGeneration, generation == detailGeneration,
                !(error is CancellationError)
            else { return }
            let failure = error as? InventoryFailure ?? .unavailable
            detailFailure = failure
            if failure == .unauthenticated || failure == .forbidden { record(failure) }
        }
    }

    func delete(_ item: Item, confirmed: Bool) async -> Bool {
        guard confirmed, isActive, !isDeactivating, !isRemovingPhoto, accessFailure == nil,
            item.householdId == householdID
        else {
            return false
        }
        let generation = lifecycleGeneration
        mutationFailure = nil
        do {
            try await repository.delete(id: item.id, expectedVersion: item.version)
            guard isActive, generation == lifecycleGeneration else { return false }
            items.removeAll { $0.id == item.id }
            if detail?.id == item.id { clearDetail() }
            await refresh()
            return true
        } catch {
            if !(error is CancellationError), isActive, generation == lifecycleGeneration {
                let failure = error as? InventoryFailure ?? .unavailable
                mutationFailure = failure
                if failure == .unauthenticated || failure == .forbidden { record(failure) }
                if failure == .conflict { await loadDetail(id: item.id) }
            }
            return false
        }
    }

    @discardableResult
    func beginDraft(item: Item? = nil) -> Bool {
        guard isActive, !isDeactivating, accessFailure == nil, !isPreparingPhotoSave, !isRemovingPhoto else {
            return false
        }
        // An orphaned photo belongs to a new purchase, never an existing item's text edit.
        guard item == nil || photoDraft?.needsDiscardConfirmation != true else { return false }
        mutationFailure = nil
        let began = drafts.begin(item: item)
        if began {
            cancelRecognition(state: .idle)
            recognitionNeedsNewRequest = false
        }
        return began
    }

    @discardableResult
    func requestRecognition() async -> RecognitionResult? {
        guard isActive, !isDeactivating, accessFailure == nil, !isPreparingPhotoSave,
            !recognitionState.isWorking, let recognitions, let photoDraft,
            let startingDraft = drafts.draft, startingDraft.baseItem == nil,
            startingDraft.phase == .editing, let startingImageID = photoDraft.draft?.id
        else { return nil }
        let generation = UUID()
        recognitionGeneration = generation
        recognitionState = .preparing(recognitions.source)
        let renew = recognitionNeedsNewRequest
        guard let identity = await photoDraft.recognitionRequest(renewing: renew) else {
            guard generation == recognitionGeneration else { return nil }
            recognitionState = .failed(Self.recognitionFailure(from: photoDraft.uploadFailure))
            return nil
        }
        guard generation == recognitionGeneration, isActive, !isDeactivating,
            drafts.draft?.id == startingDraft.id, photoDraft.draft?.id == startingImageID
        else { return nil }
        recognitionState = .recognizing(recognitions.source)
        let task = Task { try await recognitions.recognize(photoID: identity.photoId, requestID: identity.requestId) }
        recognitionTask = task
        defer { if generation == recognitionGeneration { recognitionTask = nil } }
        do {
            let result = try await task.value
            guard generation == recognitionGeneration, isActive, !isDeactivating,
                let current = drafts.draft, current.id == startingDraft.id,
                current.phase == .editing, photoDraft.draft?.id == startingImageID
            else { return nil }
            recognitionNeedsNewRequest = false
            switch result {
            case .suggested(let suggestion):
                guard current.fields == startingDraft.fields else {
                    recognitionState = .stale
                    return result
                }
                var fields = suggestion.fields
                fields.purchasedOn = current.fields.purchasedOn
                fields.quantity = current.fields.quantity
                fields.restockLimit = current.fields.restockLimit
                guard drafts.edit(fields) else {
                    recognitionState = .stale
                    return result
                }
                recognitionState = .suggested(recognitions.source)
            case .unrecognized(let reason):
                recognitionState = .unrecognized(recognitions.source, reason)
            }
            return result
        } catch is CancellationError {
            return nil
        } catch {
            guard generation == recognitionGeneration, isActive, !isDeactivating else { return nil }
            let failure = error as? RecognitionFailure ?? .unavailable
            if failure == .retryRequired {
                recognitionNeedsNewRequest = true
                _ = await photoDraft.markRecognitionRetryRequired()
                guard generation == recognitionGeneration, isActive, !isDeactivating else { return nil }
            }
            recognitionState = .failed(failure)
            if failure == .unauthenticated { record(.unauthenticated) }
            if failure == .forbidden { record(.forbidden) }
            return nil
        }
    }

    func continueManually() {
        cancelRecognition(state: .manual)
    }

    func photoDraftChanged() {
        cancelRecognition(state: .idle)
        recognitionNeedsNewRequest = false
    }

    func removePhoto(from item: Item, confirmed: Bool) async -> Bool {
        guard confirmed, isActive, !isDeactivating, accessFailure == nil, !isRemovingPhoto,
            !isPreparingPhotoSave, !drafts.isSaving, drafts.hasLoaded, drafts.storageFailure == nil,
            drafts.draft == nil,
            photoDraft?.needsDiscardConfirmation != true, item.householdId == householdID
        else { return false }
        isRemovingPhoto = true
        defer { isRemovingPhoto = false }
        let generation = lifecycleGeneration
        mutationFailure = nil
        do {
            let updated = try await repository.removePhoto(itemID: item.id, expectedVersion: item.version)
            guard isActive, generation == lifecycleGeneration else { return false }
            if let current = detail, current.id == item.id, current.version <= updated.version {
                clearDetail()
                detail = updated
            }
            await refresh()
            return true
        } catch {
            guard isActive, generation == lifecycleGeneration, !(error is CancellationError) else { return false }
            let failure = error as? InventoryFailure ?? .unavailable
            mutationFailure = failure
            if failure == .unauthenticated || failure == .forbidden { record(failure) }
            if failure == .conflict, detail?.id == item.id { await loadDetail(id: item.id) }
            return false
        }
    }

    @discardableResult
    func discardDraft(confirmed: Bool) async -> Bool {
        guard confirmed, isActive, !isDeactivating, !isPreparingPhotoSave else { return false }
        cancelRecognition(state: .idle)
        if let photoDraft, !(await photoDraft.discard(confirmed: true)) { return false }
        let generation = lifecycleGeneration
        guard await drafts.discard(confirmed: true), isActive, generation == lifecycleGeneration else {
            return false
        }
        mutationFailure = nil
        await refresh()
        return true
    }

    @discardableResult
    func retire() async -> Bool {
        guard !isDeactivating else { return false }
        isDeactivating = true
        defer { isDeactivating = false }
        cancelRecognition(state: .idle)
        lifecycleGeneration = UUID()
        clearDetail()
        clearThumbnails()
        requestGeneration = UUID()
        searchTask?.cancel()
        isLoading = false
        // Hide shared data immediately; preserve the private draft before releasing this instance.
        items = []
        nextOffset = nil
        lastUpdated = nil
        mutationFailure = nil
        guard await drafts.retire() else { return false }
        if let photoDraft, !(await photoDraft.close(discard: false)) { return false }
        isActive = false
        return true
    }

    @discardableResult
    func deactivate(confirmedDiscard: Bool) async -> Bool {
        guard !isDeactivating else { return false }
        // Only invalidate this store when the draft controller accepts the confirmation.
        guard
            confirmedDiscard
                || (drafts.hasLoaded && drafts.draft == nil && drafts.storageFailure == nil
                    && photoDraft?.needsDiscardConfirmation != true)
        else {
            return false
        }
        isDeactivating = true
        defer { isDeactivating = false }
        cancelRecognition(state: .idle)
        lifecycleGeneration = UUID()
        clearDetail()
        clearThumbnails()
        requestGeneration = UUID()
        searchTask?.cancel()
        isLoading = false
        guard await drafts.deactivate(confirmedDiscard: confirmedDiscard) else { return false }
        if let photoDraft, !(await photoDraft.close(discard: true)) { return false }
        isActive = false
        items = []
        query = ""
        nextOffset = nil
        lastUpdated = nil
        isLoading = false
        failure = nil
        mutationFailure = nil
        return true
    }

    private func resetSearch() -> UUID {
        clearThumbnails()
        searchTask?.cancel()
        requestGeneration = UUID()
        items = []
        nextOffset = nil
        failure = nil
        isLoading = true
        return requestGeneration
    }

    private func fetch(offset: Int, generation: UUID) async {
        guard isActive, accessFailure == nil, generation == requestGeneration else { return }
        isLoading = true
        defer { if generation == requestGeneration { isLoading = false } }
        do {
            let page = try await repository.search(.init(householdId: householdID, query: query, offset: offset))
            guard isActive, generation == requestGeneration, !Task.isCancelled else { return }
            // Concurrent server changes may shift offset pages. Keep stable IDs without duplicate rows.
            if offset == 0 {
                items = page.data
            } else {
                let incoming = Set(page.data.map(\.id))
                items.removeAll { incoming.contains($0.id) }
                items.append(contentsOf: page.data)
            }
            nextOffset = page.nextOffset
            lastUpdated = Date()
            failure = nil
        } catch {
            guard isActive, generation == requestGeneration, !(error is CancellationError), !Task.isCancelled else {
                return
            }
            record(error as? InventoryFailure ?? .unavailable, collection: true)
        }
    }

    private func record(_ error: InventoryFailure, collection: Bool = false) {
        failure = error
        if error == .unauthenticated || error == .forbidden || (collection && error == .notFound) {
            accessFailure = error
            clearDetail()
            clearThumbnails()
            items = []
            nextOffset = nil
            lastUpdated = nil
            requestGeneration = UUID()
            searchTask?.cancel()
            isLoading = false
        }
    }

    private func clearDetail() {
        detailGeneration = UUID()
        detailPhoto.clear()
        detail = nil
        detailFailure = nil
        isLoadingDetail = false
    }

    private func recordPhotoAccessFailure(_ error: PhotoFailure?) {
        if error == .unauthenticated { record(.unauthenticated) }
        if error == .forbidden { record(.forbidden) }
    }

    private func cancelRecognition(state: RecognitionFlowState) {
        recognitionGeneration = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionState = state
    }

    private static func recognitionFailure(from photoFailure: PhotoFailure?) -> RecognitionFailure {
        switch photoFailure {
        case .unauthenticated: .unauthenticated
        case .forbidden: .forbidden
        case .notFound: .notFound
        case .validation, .expired, .uploadIncomplete, .conflict, .invalidResponse: .validation
        case .protectedStorage, .unavailable, nil: .unavailable
        }
    }
}
