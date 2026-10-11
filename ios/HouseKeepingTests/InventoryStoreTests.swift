import Foundation
import Testing

@testable import HouseKeeping

@MainActor
struct InventoryStoreTests {
    @Test func uncertainPhotoSaveKeepsExactPhotoAndRequestAfterReconstruction() async throws {
        let storage = MemoryDraftStore()
        let repository = ControlledInventoryRepository()
        let controller = InventoryDraftController(storage: storage, repository: repository)
        await controller.restore()
        #expect(controller.begin())
        #expect(controller.edit(.init(name: "Photo purchase")))
        let photoID = UUID()
        let saving = Task { await controller.save(photoId: photoID) }
        await waitUntil { repository.creates.count == 1 }
        let submitted = try #require(repository.creates.first)
        #expect(submitted.photoId == photoID)
        #expect(storage.value?.photoId == photoID && storage.value?.phase == .submitting)
        repository.finishCreate(.failure(InventoryFailure.unavailable))
        #expect(await saving.value == nil)
        #expect(await controller.retire())

        let restored = InventoryDraftController(storage: storage, repository: repository)
        await restored.restore()
        // Even an incorrect new caller selection cannot mutate the persisted uncertain command.
        let retry = Task { await restored.save(photoId: UUID()) }
        await waitUntil { repository.creates.count == 2 }
        #expect(repository.creates[1] == submitted)
        repository.finishCreate(.success(fixtureItem(storage.owner, name: "Photo purchase")))
        #expect(await retry.value != nil)
        #expect(storage.value == nil)
    }

    @Test func latestQueryWinsEvenWhenOldRequestIgnoresCancellation() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage, debounce: .zero)
        store.setQuery("old")
        await waitUntil { repository.searches.count == 1 }
        store.setQuery("new")
        await waitUntil { repository.searches.count == 2 }
        let newest = fixtureItem(storage.owner, name: "Newest")
        repository.finishSearch(1, .success(.init(data: [newest], nextOffset: nil)))
        await waitUntil { !store.isLoading }
        repository.finishSearch(0, .success(.init(data: [fixtureItem(storage.owner, name: "Stale")], nextOffset: nil)))
        await Task.yield()
        #expect(store.items == [newest])
        #expect(store.query == "new")
        #expect(store.lastUpdated != nil)
    }

    @Test func paginationRefreshAndFailuresHaveDistinctState() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        let first = fixtureItem(storage.owner, name: "First")
        let second = fixtureItem(storage.owner, name: "Second")
        let refresh = Task { await store.refresh() }
        await waitUntil { repository.searches.count == 1 }
        repository.finishSearch(0, .success(.init(data: [first], nextOffset: 50)))
        await refresh.value
        let more = Task { await store.loadMore() }
        await waitUntil { repository.searches.count == 2 }
        #expect(repository.searches[1].offset == 50)
        repository.finishSearch(1, .success(.init(data: [first, second], nextOffset: nil)))
        await more.value
        #expect(store.items.map(\.id) == [first.id, second.id])
        let offline = Task { await store.refresh() }
        await waitUntil { repository.searches.count == 3 }
        repository.finishSearch(2, .failure(InventoryFailure.unavailable))
        await offline.value
        #expect(store.failure == .unavailable && store.items.isEmpty && store.nextOffset == nil)
        let retry = Task { await store.refresh() }
        await waitUntil { repository.searches.count == 4 }
        repository.finishSearch(3, .success(.init(data: [], nextOffset: nil)))
        await retry.value
        #expect(store.failure == nil && store.items.isEmpty)
    }

    @Test func timeoutAndRelaunchReuseOriginalRequestWithoutLosingFields() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let draft = InventoryDraftController(storage: storage, repository: repository)
        await draft.restore()
        #expect(draft.begin())
        #expect(draft.edit(.init(name: "Kettle", description: "Keep these edits")))
        let firstSave = Task { await draft.save() }
        await waitUntil { repository.creates.count == 1 }
        #expect(storage.value?.phase == .submitting)
        #expect(!draft.edit(.init(name: "Would alter uncertain request")))
        repository.finishCreate(.failure(InventoryFailure.unavailable))
        #expect(await firstSave.value == nil)
        #expect(draft.draft?.fields.description == "Keep these edits")
        let relaunched = InventoryDraftController(storage: storage, repository: repository)
        await relaunched.restore()
        let retry = Task { await relaunched.save() }
        await waitUntil { repository.creates.count == 2 }
        #expect(repository.creates[0] == repository.creates[1])
        let saved = fixtureItem(storage.owner, name: "Kettle")
        repository.finishCreate(.success(saved))
        #expect(await retry.value == saved)
        #expect(relaunched.draft == nil && storage.value == nil)
    }

    @Test func failedDiskWritePreventsNetworkAndRetainsEditableDraft() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let draft = InventoryDraftController(storage: storage, repository: repository)
        await draft.restore()
        #expect(draft.begin())
        #expect(draft.edit(.init(name: "Kettle")))
        storage.failSave = true
        #expect(await draft.save() == nil)
        #expect(repository.creates.isEmpty)
        #expect(draft.draft?.fields.name == "Kettle")
        #expect(draft.storageFailure == .unavailable)
        #expect(draft.edit(.init(name: "Still editable")))
        storage.failSave = false
        #expect(await draft.flush())
    }

    @Test func acknowledgmentSurvivesCleanupFailureAndDoesNotRepeatSave() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let draft = InventoryDraftController(storage: storage, repository: repository)
        await draft.restore()
        _ = draft.begin()
        _ = draft.edit(.init(name: "Kettle"))
        storage.failClear = true
        let save = Task { await draft.save() }
        await waitUntil { repository.creates.count == 1 }
        let item = fixtureItem(storage.owner, name: "Kettle")
        repository.finishCreate(.success(item))
        #expect(await save.value == nil)
        #expect(storage.value?.phase == .acknowledged(item))
        let restored = InventoryDraftController(storage: storage, repository: repository)
        await restored.restore()
        storage.failClear = false
        #expect(await restored.save() == item)
        #expect(repository.creates.count == 1 && storage.value == nil)
    }

    @Test func discardingAcknowledgedRetryCopyRefreshesSharedInventory() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage, debounce: .zero)
        await store.drafts.restore()
        #expect(store.beginDraft())
        #expect(store.drafts.edit(.init(name: "Saved kettle")))
        storage.failClear = true
        let save = Task { await store.saveDraft() }
        await waitUntil { repository.creates.count == 1 }
        let item = fixtureItem(storage.owner, name: "Saved kettle")
        repository.finishCreate(.success(item))
        #expect(await save.value == nil)
        #expect(store.drafts.draft?.phase == .acknowledged(item))

        storage.failClear = false
        let discard = Task { await store.discardDraft(confirmed: true) }
        await waitUntil { repository.searches.count == 1 }
        repository.finishSearch(0, .success(.init(data: [item], nextOffset: nil)))
        #expect(await discard.value)
        #expect(store.drafts.draft == nil && store.items == [item])
        #expect(repository.creates.count == 1)
    }

    @Test func rapidEditsArePersistedInOrderAndLatestSurvivesRestore() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        storage.holdWrites = true
        let draft = InventoryDraftController(storage: storage, repository: repository)
        await draft.restore()
        _ = draft.begin()
        _ = draft.edit(.init(name: "First"))
        await waitUntil { storage.pendingWrite != nil }
        _ = draft.edit(.init(name: "Latest"))
        storage.holdWrites = false
        storage.releaseWrite()
        #expect(await draft.flush())
        #expect(storage.value?.fields.name == "Latest")
        let restored = InventoryDraftController(storage: storage, repository: repository)
        await restored.restore()
        #expect(restored.draft?.fields.name == "Latest")
    }

    @Test func deactivationWaitsForFileWriteAndRejectsLateNetworkData() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        await store.drafts.restore()
        _ = store.drafts.begin()
        _ = store.drafts.edit(.init(name: "Private text"))
        #expect(!(await store.deactivate(confirmedDiscard: false)))
        storage.holdWrites = true
        let flushing = Task { await store.drafts.flush() }
        await waitUntil { storage.pendingWrite != nil }
        let searching = Task { await store.refresh() }
        await waitUntil { repository.searches.count == 1 }
        let closing = Task { await store.deactivate(confirmedDiscard: true) }
        await waitUntil { store.isDeactivating }
        #expect(store.drafts.draft?.fields.name == "Private text")
        storage.holdWrites = false
        storage.releaseWrite()
        _ = await flushing.value
        #expect(await closing.value)
        repository.finishSearch(0, .success(.init(data: [fixtureItem(storage.owner)], nextOffset: nil)))
        await searching.value
        #expect(!store.isActive && store.items.isEmpty && storage.value == nil)
        #expect(store.drafts.draft == nil)
        #expect(!store.drafts.begin())
    }

    @Test func failedDeactivationPreservesQueuedEditsAndAllowsCleanupRetry() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        await store.drafts.restore()
        storage.holdWrites = true
        _ = store.drafts.begin()
        await waitUntil { storage.pendingWrite != nil }
        _ = store.drafts.edit(.init(name: "First queued edit"))
        _ = store.drafts.edit(.init(name: "Latest queued edit"))
        storage.failClear = true
        let closing = Task { await store.deactivate(confirmedDiscard: true) }
        await waitUntil { store.drafts.isDeactivating }
        #expect(!store.drafts.edit(.init(name: "Not allowed during cleanup")))
        storage.holdWrites = false
        storage.releaseWrite()
        #expect(!(await closing.value))
        #expect(store.isActive && store.drafts.isActive && !store.isDeactivating)
        #expect(store.drafts.draft?.fields.name == "Latest queued edit")
        #expect(storage.value?.fields.name == "Latest queued edit")
        #expect(store.drafts.storageFailure == .unavailable)
        #expect(store.drafts.edit(.init(name: "Still usable")))
        #expect(await store.drafts.flush())
        storage.failClear = false
        #expect(await store.deactivate(confirmedDiscard: true))
        #expect(!store.isActive && storage.value == nil && store.drafts.draft == nil)
    }

    @Test func lateSaveAcknowledgmentCannotResurrectDeactivatedDraft() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        await store.drafts.restore()
        _ = store.drafts.begin()
        _ = store.drafts.edit(.init(name: "Pending purchase"))
        let saving = Task { await store.saveDraft() }
        await waitUntil { repository.creates.count == 1 }
        #expect(await store.deactivate(confirmedDiscard: true))
        repository.finishCreate(.success(fixtureItem(storage.owner, name: "Pending purchase")))
        await saving.value
        #expect(store.drafts.draft == nil && storage.value == nil)
        #expect(store.drafts.lastSavedItem == nil && store.items.isEmpty)
        #expect(repository.searches.isEmpty)
    }

    @Test func conflictReviewMergesOnlyExplicitEditsOntoNewVersion() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let draft = InventoryDraftController(storage: storage, repository: repository)
        await draft.restore()
        let old = fixtureItem(storage.owner, name: "Old", brand: "Old brand")
        _ = draft.begin(item: old)
        var fields = old.fields
        fields.name = "My edit"
        _ = draft.edit(fields)
        repository.updateFailure = .conflict
        #expect(await draft.save() == nil)
        #expect(draft.draft?.fields.name == "My edit")
        let latest = fixtureItem(storage.owner, id: old.id, name: "Old", brand: "Spouse's brand", version: 2)
        repository.latest = latest
        await draft.reviewConflict()
        #expect(draft.resolveConflict(keepingChanges: true))
        #expect(draft.draft?.fields.name == "My edit")
        #expect(draft.draft?.fields.brand == "Spouse's brand")
        #expect(draft.draft?.baseItem?.version == 2)
        #expect(draft.draft?.patch.brand == .unchanged)
        _ = await draft.flush()
    }

    @Test func lostAccessClearsResultsAndBlocksFurtherInventoryRequests() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        let task = Task { await store.refresh() }
        await waitUntil { repository.searches.count == 1 }
        repository.finishSearch(0, .failure(InventoryFailure.notFound))
        await task.value
        #expect(store.accessFailure == .notFound && store.items.isEmpty)
        await store.refresh()
        await store.saveDraft()
        #expect(repository.searches.count == 1 && repository.creates.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Expected controlled operation did not start")
    }

    @Test func retirementPreservesUncertainInputAndRejectsLateAcknowledgment() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        await store.drafts.restore()
        _ = store.drafts.begin()
        _ = store.drafts.edit(.init(name: "Pending purchase"))
        let saving = Task { await store.saveDraft() }
        await waitUntil { repository.creates.count == 1 }
        let submitted = storage.value
        #expect(await store.retire())
        repository.finishCreate(.success(fixtureItem(storage.owner)))
        await saving.value
        #expect(storage.value == submitted && storage.value?.phase == .submitting)
        #expect(store.drafts.draft == nil && store.drafts.lastSavedItem == nil)
        #expect(repository.searches.isEmpty && !store.isActive)
    }

    @Test func detailResultsAreIndependentOfPagesAndRejectedAfterRetirement() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        let item = fixtureItem(storage.owner)
        repository.latest = item
        await store.loadDetail(id: item.id)
        #expect(store.detail == item && store.items.isEmpty)
        repository.holdGet = true
        let loading = Task { await store.loadDetail(id: item.id) }
        await waitUntil { repository.getContinuation != nil }
        #expect(store.detail == nil && store.isLoadingDetail)
        #expect(await store.retire())
        repository.getContinuation?.resume(returning: item)
        await loading.value
        #expect(store.detail == nil && !store.isLoadingDetail && store.detailFailure == nil)
    }

    @Test func missingDetailDoesNotBlockCollectionButDeniedAccessDoes() async {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        repository.getFailure = .notFound
        await store.loadDetail(id: UUID())
        #expect(store.detailFailure == .notFound && store.accessFailure == nil)
        repository.getFailure = .forbidden
        await store.loadDetail(id: UUID())
        #expect(store.accessFailure == .forbidden && store.detail == nil)
        #expect(!store.isLoadingDetail)
    }

    @Test func photoRemovalPreservesFailuresAndRefreshesConflictsBeforeExplicitRetry() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        await store.drafts.restore()
        let original = fixtureItem(storage.owner, photoID: UUID())
        repository.latest = original
        await store.loadDetail(id: original.id)
        #expect(!(await store.removePhoto(from: original, confirmed: false)))
        #expect(repository.removals.isEmpty)
        repository.removalFailure = .unavailable
        #expect(!(await store.removePhoto(from: original, confirmed: true)))
        #expect(store.detail == original && store.mutationFailure == .unavailable)
        repository.removalFailure = .conflict
        repository.latest = fixtureItem(
            storage.owner, id: original.id, brand: "Spouse edit", version: 2, photoID: original.photoId)
        #expect(!(await store.removePhoto(from: original, confirmed: true)))
        #expect(store.detail?.version == 2 && store.detail?.brand == "Spouse edit")
        let retry = try #require(store.detail)
        repository.removalFailure = nil
        let removed = fixtureItem(storage.owner, id: original.id, brand: "Spouse edit", version: 3)
        repository.latest = removed
        let removing = Task { await store.removePhoto(from: retry, confirmed: true) }
        await waitUntil { repository.searches.count == 1 }
        repository.finishSearch(0, .success(.init(data: [removed], nextOffset: nil)))
        #expect(await removing.value)
        #expect(store.detail == removed && store.items == [removed] && store.mutationFailure == nil)
        #expect(repository.removals.map(\.expectedVersion) == [1, 1, 2])
    }

    @Test func latePhotoRemovalDoesNotResurrectRetiredDetailsOrAllowConcurrentMutation() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        await store.drafts.restore()
        let original = fixtureItem(storage.owner, photoID: UUID())
        repository.latest = original
        await store.loadDetail(id: original.id)
        repository.holdRemoval = true
        let removing = Task { await store.removePhoto(from: original, confirmed: true) }
        await waitUntil { repository.removalContinuation != nil }
        #expect(!store.beginDraft())
        #expect(!(await store.removePhoto(from: original, confirmed: true)))
        #expect(!(await store.delete(original, confirmed: true)))
        #expect(await store.retire())
        repository.removalContinuation?.resume(returning: fixtureItem(storage.owner, id: original.id, version: 2))
        #expect(!(await removing.value))
        #expect(store.detail == nil && store.items.isEmpty && repository.searches.isEmpty)
        #expect(repository.removals.count == 1 && repository.deletes.isEmpty)
    }

    @Test func staleDeleteReloadsLatestItemAndCanBeRetried() async throws {
        let repository = ControlledInventoryRepository()
        let storage = MemoryDraftStore()
        let store = InventoryStore(repository: repository, draftStorage: storage)
        let original = fixtureItem(storage.owner, version: 1)
        repository.latest = original
        await store.loadDetail(id: original.id)
        repository.deleteFailure = .conflict
        repository.latest = fixtureItem(storage.owner, id: original.id, brand: "Spouse edit", version: 2)
        #expect(!(await store.delete(original, confirmed: true)))
        #expect(store.mutationFailure == .conflict)
        #expect(store.detail?.version == 2 && store.detail?.brand == "Spouse edit")
        repository.deleteFailure = nil
        let retry = try #require(store.detail)
        let deletion = Task { await store.delete(retry, confirmed: true) }
        await waitUntil { repository.searches.count == 1 }
        repository.finishSearch(0, .success(.init(data: [], nextOffset: nil)))
        #expect(await deletion.value)
        #expect(repository.deletes.map(\.expectedVersion) == [1, 2])
        #expect(store.mutationFailure == nil && store.detail == nil)
    }
}

@MainActor
private final class MemoryDraftStore: DraftStorage {
    let owner = DraftOwner(accountID: UUID(), householdID: UUID())
    var value: TextDraft?
    var failSave = false
    var failClear = false
    var holdWrites = false
    var pendingWrite: CheckedContinuation<Void, Never>?
    func load() async throws -> TextDraft? { value }
    func save(_ draft: TextDraft) async throws {
        if holdWrites { await withCheckedContinuation { pendingWrite = $0 } }
        if failSave { throw DraftStorageFailure.unavailable }
        value = draft
    }
    func clear() async throws {
        if failClear { throw DraftStorageFailure.unavailable }
        value = nil
    }
    func releaseWrite() {
        pendingWrite?.resume()
        pendingWrite = nil
    }
}

@MainActor
private final class ControlledInventoryRepository: InventoryRepository {
    var searches: [ItemQuery] = []
    var searchContinuations: [Int: CheckedContinuation<ItemPage, any Error>] = [:]
    var creates: [CreateItemInput] = []
    var createContinuation: CheckedContinuation<Item, any Error>?
    var latest: Item?
    var updateFailure: InventoryFailure?
    var getFailure: InventoryFailure?
    var holdGet = false
    var getContinuation: CheckedContinuation<Item, any Error>?
    var deleteFailure: InventoryFailure?
    var deletes: [(id: UUID, expectedVersion: Int64)] = []
    var removals: [(id: UUID, expectedVersion: Int64)] = []
    var removalFailure: InventoryFailure?
    var holdRemoval = false
    var removalContinuation: CheckedContinuation<Item, any Error>?
    func search(_ query: ItemQuery) async throws -> ItemPage {
        let index = searches.count
        searches.append(query)
        return try await withCheckedThrowingContinuation { searchContinuations[index] = $0 }
    }
    func create(_ input: CreateItemInput) async throws -> Item {
        creates.append(input)
        return try await withCheckedThrowingContinuation { createContinuation = $0 }
    }
    func get(id: UUID) async throws -> Item {
        if let getFailure { throw getFailure }
        if holdGet { return try await withCheckedThrowingContinuation { getContinuation = $0 } }
        return try #require(latest)
    }
    func update(_ input: UpdateItemInput) async throws -> Item {
        if let updateFailure { throw updateFailure }
        return try #require(latest)
    }
    func delete(id: UUID, expectedVersion: Int64) async throws {
        deletes.append((id, expectedVersion))
        if let deleteFailure { throw deleteFailure }
    }
    func finishSearch(_ index: Int, _ result: Result<ItemPage, any Error>) {
        searchContinuations.removeValue(forKey: index)?.resume(with: result)
    }
    func removePhoto(itemID: UUID, expectedVersion: Int64) async throws -> Item {
        removals.append((itemID, expectedVersion))
        if holdRemoval { return try await withCheckedThrowingContinuation { removalContinuation = $0 } }
        if let removalFailure { throw removalFailure }
        return try #require(latest)
    }
    func finishCreate(_ result: Result<Item, any Error>) {
        createContinuation?.resume(with: result)
        createContinuation = nil
    }
}

private func fixtureItem(
    _ owner: DraftOwner, id: UUID = UUID(), name: String = "Kettle", brand: String? = nil, version: Int64 = 1,
    photoID: UUID? = nil
) -> Item {
    Item(
        id: id, householdId: owner.householdID, name: name, description: nil, brand: brand, model: nil,
        purchasedOn: nil, photoId: photoID, createdAt: Date(), updatedAt: Date(), version: version)
}
