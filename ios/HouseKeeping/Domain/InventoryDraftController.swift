import Foundation
import Observation

/// Own once per account session. Disk writes are ordered; a submitted draft is frozen until resolved.
@MainActor @Observable
final class InventoryDraftController {
    private(set) var draft: TextDraft?
    private(set) var hasLoaded = false
    private(set) var isSaving = false
    private(set) var isPersisting = false
    private(set) var storageFailure: DraftStorageFailure?
    private(set) var saveFailure: InventoryFailure?
    private(set) var conflictItem: Item?
    private(set) var lastSavedItem: Item?
    private(set) var isActive = true
    private(set) var isDeactivating = false
    private let storage: any DraftStorage
    private let repository: any InventoryRepository
    @ObservationIgnored private var persistence: Task<Bool, Never>?
    @ObservationIgnored private var persistenceRevision = UUID()
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var operationGeneration = UUID()

    private var canWork: Bool { isActive && !isDeactivating }
    private func isCurrent(_ generation: UUID) -> Bool { canWork && generation == operationGeneration }

    init(storage: any DraftStorage, repository: any InventoryRepository) {
        self.storage = storage
        self.repository = repository
    }

    func restore() async {
        guard canWork, !hasLoaded, !isRestoring else { return }
        let generation = operationGeneration
        isRestoring = true
        defer { isRestoring = false }
        do {
            let loaded = try await storage.load()
            guard isCurrent(generation) else { return }
            guard loaded == nil || loaded?.owner == storage.owner else { throw DraftStorageFailure.invalidData }
            draft = loaded
            hasLoaded = true
            storageFailure = nil
        } catch { if isCurrent(generation) { storageFailure = error as? DraftStorageFailure ?? .unavailable } }
    }

    @discardableResult
    func begin(item: Item? = nil) -> Bool {
        guard canWork, hasLoaded, draft == nil, !isSaving,
            item == nil || item?.householdId == storage.owner.householdID
        else { return false }
        draft = TextDraft(owner: storage.owner, fields: item?.fields ?? .init(name: ""), baseItem: item)
        saveFailure = nil
        lastSavedItem = nil
        schedulePersistence()
        return true
    }

    @discardableResult
    func edit(_ fields: ItemFields) -> Bool {
        guard canWork, !isSaving, var current = draft, current.phase == .editing else { return false }
        current.fields = fields
        draft = current
        saveFailure = nil
        schedulePersistence()
        return true
    }

    @discardableResult
    func flush() async -> Bool {
        guard canWork else { return false }
        if draft != nil, !isSaving { schedulePersistence() }
        return await persistence?.value ?? true
    }

    func save(photoId: UUID? = nil) async -> Item? {
        guard canWork, !isSaving, var current = draft else { return nil }
        let generation = operationGeneration
        isSaving = true
        saveFailure = nil
        defer { if generation == operationGeneration { isSaving = false } }
        do {
            if case .acknowledged = current.phase {
                return await finishAcknowledgment(generation: generation)
            }
            try current.fields.validate()
            let wasEditing = current.phase == .editing
            // Only an editable draft may choose its photo. Retries keep the persisted exact input.
            if wasEditing {
                guard current.baseItem == nil || photoId == nil else { throw InventoryFailure.validation }
                current.photoId = photoId
                current.rejectedPhotoId = nil
            }
            // Persist the exact input and request UUID before any network mutation.
            current.phase = .submitting
            draft = current
            guard await persistCurrent(), isCurrent(generation) else {
                if isCurrent(generation), wasEditing { draft?.phase = .editing }
                return nil
            }
            let saved: Item
            if let base = current.baseItem {
                if current.patch == ItemPatch() {
                    saved = base
                } else {
                    saved = try await repository.update(
                        .init(id: base.id, expectedVersion: base.version, fields: current.patch))
                }
            } else {
                saved = try await repository.create(
                    .init(
                        householdId: current.owner.householdID, requestId: current.id, fields: current.fields,
                        photoId: current.photoId))
            }
            guard isCurrent(generation) else { return nil }
            current.phase = .acknowledged(saved)
            draft = current
            lastSavedItem = saved
            return await finishAcknowledgment(generation: generation)
        } catch {
            guard isCurrent(generation) else { return nil }
            if !(error is CancellationError) { saveFailure = error as? InventoryFailure ?? .unavailable }
            // Validation/readiness rejection is definite; other failures may have committed remotely.
            if saveFailure == .validation || (saveFailure == .photoNotReady && current.baseItem == nil) {
                draft?.phase = .editing
                if saveFailure == .photoNotReady {
                    draft?.rejectedPhotoId = current.photoId
                    draft?.photoId = nil
                }
                _ = await persistCurrent()
            }
            return nil
        }
    }

    func reviewConflict() async {
        guard canWork, !isSaving, saveFailure == .conflict, let base = draft?.baseItem else { return }
        let generation = operationGeneration
        isSaving = true
        defer { if generation == operationGeneration { isSaving = false } }
        do {
            let latest = try await repository.get(id: base.id)
            guard isCurrent(generation) else { return }
            conflictItem = latest
        } catch { if isCurrent(generation) { saveFailure = error as? InventoryFailure ?? .unavailable } }
    }

    func acknowledgePhotoReset() async -> Bool {
        guard canWork, !isSaving, draft?.phase == .editing else { return false }
        draft?.rejectedPhotoId = nil
        return await persistCurrent()
    }

    @discardableResult
    func resolveConflict(keepingChanges: Bool) -> Bool {
        guard canWork, !isSaving, let latest = conflictItem, let current = draft,
            current.baseItem?.id == latest.id, latest.householdId == current.owner.householdID
        else { return false }
        draft = current.rebased(on: latest, keepingChanges: keepingChanges)
        conflictItem = nil
        saveFailure = nil
        schedulePersistence()
        return true
    }

    /// Caller must obtain an explicit discard confirmation in the editor/sign-out UI.
    @discardableResult
    func discard(confirmed: Bool) async -> Bool {
        guard confirmed, canWork, !isSaving else { return false }
        let generation = operationGeneration
        isSaving = true
        defer { if generation == operationGeneration { isSaving = false } }
        _ = await persistence?.value
        guard isCurrent(generation) else { return false }
        isPersisting = false
        do {
            try await storage.clear()
            guard isCurrent(generation) else { return false }
            draft = nil
            conflictItem = nil
            storageFailure = nil
            saveFailure = nil
            hasLoaded = true
            return true
        } catch {
            if isCurrent(generation) { storageFailure = error as? DraftStorageFailure ?? .unavailable }
            return false
        }
    }

    /// Suspend this instance for account revalidation without discarding its partitioned file.
    @discardableResult
    func retire() async -> Bool {
        guard !isDeactivating else { return false }
        if !isActive { return true }
        if draft != nil { schedulePersistence() }
        isDeactivating = true
        operationGeneration = UUID()
        defer {
            isDeactivating = false
            isSaving = false
        }
        let persisted = await persistence?.value ?? true
        guard persisted else { return false }
        isActive = false
        draft = nil
        conflictItem = nil
        lastSavedItem = nil
        return true
    }

    /// Reject unconfirmed sign-out with a draft (or unreadable draft file). Late work cannot resurrect it.
    @discardableResult
    func deactivate(confirmedDiscard: Bool) async -> Bool {
        guard !isDeactivating else { return false }
        guard confirmedDiscard || (hasLoaded && draft == nil && storageFailure == nil) else { return false }
        isDeactivating = true
        operationGeneration = UUID()
        defer {
            isDeactivating = false
            isSaving = false
        }
        // Keep the controller active so every already-queued snapshot can finish. Do not
        // erase the latest in-memory text until removal is acknowledged by protected storage.
        _ = await persistence?.value
        isPersisting = false
        do {
            try await storage.clear()
            isActive = false
            draft = nil
            conflictItem = nil
            lastSavedItem = nil
            storageFailure = nil
            return true
        } catch {
            storageFailure = error as? DraftStorageFailure ?? .unavailable
            return false
        }
    }

    private func finishAcknowledgment(generation: UUID) async -> Item? {
        guard case .acknowledged(let saved) = draft?.phase else { return nil }
        lastSavedItem = saved
        guard await persistCurrent(), isCurrent(generation) else { return nil }
        do {
            try await storage.clear()
            guard isCurrent(generation) else { return nil }
            draft = nil
            conflictItem = nil
            storageFailure = nil
            return saved
        } catch {
            if isCurrent(generation) { storageFailure = error as? DraftStorageFailure ?? .unavailable }
            return nil
        }
    }

    private func persistCurrent() async -> Bool {
        guard canWork else { return false }
        schedulePersistence()
        return await persistence?.value ?? false
    }

    private func schedulePersistence() {
        guard let snapshot = draft, isActive else { return }
        let previous = persistence
        let revision = UUID()
        persistenceRevision = revision
        isPersisting = true
        persistence = Task {
            _ = await previous?.value
            guard isActive else { return false }
            do {
                try await storage.save(snapshot)
                if revision == persistenceRevision {
                    isPersisting = false
                    storageFailure = nil
                }
                return true
            } catch {
                if revision == persistenceRevision {
                    isPersisting = false
                    storageFailure = error as? DraftStorageFailure ?? .unavailable
                }
                return false
            }
        }
    }
}
