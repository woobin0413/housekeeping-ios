#if DEBUG
    import Foundation

    /// Explicit UI fixture only: never constructed as a fallback from a live error.
    @MainActor
    final class PreviewInventoryRepository: InventoryRepository {
        private let householdID: UUID
        private let database: PreviewInventoryDatabase

        init(householdID: UUID, database: PreviewInventoryDatabase = PreviewInventoryDatabase()) {
            self.householdID = householdID
            self.database = database
            database.seedIfNeeded(householdID: householdID)
        }

        func search(_ query: ItemQuery) async throws -> ItemPage {
            try query.validate()
            guard query.householdId == householdID else { throw InventoryFailure.forbidden }
            let tokens = query.query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let matches = database.items(householdID: householdID).filter { item in
                let searchable = [item.name, item.description, item.brand, item.model]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                return tokens.allSatisfy(searchable.contains)
            }
            let end = min(query.offset + query.limit, matches.count)
            let page = query.offset < end ? Array(matches[query.offset..<end]) : []
            return ItemPage(data: page, nextOffset: end < matches.count ? end : nil)
        }
        func get(id: UUID) async throws -> Item {
            try database.item(id: id, householdID: householdID)
        }
        func create(_ input: CreateItemInput) async throws -> Item {
            guard input.householdId == householdID else { throw InventoryFailure.forbidden }
            try input.fields.validate()
            return try database.create(input)
        }
        func update(_ input: UpdateItemInput) async throws -> Item {
            try input.fields.validate()
            return try database.update(input, householdID: householdID)
        }
        func delete(id: UUID, expectedVersion: Int64) async throws {
            try database.delete(id: id, expectedVersion: expectedVersion, householdID: householdID)
        }
        func removePhoto(itemID: UUID, expectedVersion: Int64) async throws -> Item {
            try database.removePhoto(itemID: itemID, expectedVersion: expectedVersion, householdID: householdID)
        }
    }

    @MainActor
    final class PreviewInventoryDatabase {
        private var householdItems: [UUID: [Item]] = [:]
        private var requests: [UUID: (fields: ItemFields, photoID: UUID?, itemID: UUID)] = [:]
        fileprivate var photos: [UUID: PreviewPhoto] = [:]

        func seedIfNeeded(householdID: UUID) {
            guard householdItems[householdID] == nil else { return }
            householdItems[householdID] = [
                Item(
                    id: UUID(), householdId: householdID, name: "Shared kettle",
                    description: "A green kettle for the kitchen", brand: "Sample brand", model: nil,
                    purchasedOn: nil, photoId: nil, createdAt: .distantPast, updatedAt: .distantPast, version: 1)
            ]
        }

        func items(householdID: UUID) -> [Item] {
            householdItems[householdID, default: []].sorted { $0.updatedAt > $1.updatedAt }
        }

        func item(id: UUID, householdID: UUID) throws -> Item {
            guard let item = householdItems[householdID]?.first(where: { $0.id == id }) else {
                throw InventoryFailure.notFound
            }
            return item
        }

        func create(_ input: CreateItemInput) throws -> Item {
            if let request = requests[input.requestId] {
                guard request.fields == input.fields, request.photoID == input.photoId else {
                    throw InventoryFailure.conflict
                }
                return try item(id: request.itemID, householdID: input.householdId)
            }
            if let photoID = input.photoId {
                guard let photo = photos[photoID], photo.owner.householdID == input.householdId,
                    photo.ready, photo.reservation.expiresAt > Date()
                else { throw InventoryFailure.photoNotReady }
            }
            let now = Date()
            let item = Item(
                id: UUID(), householdId: input.householdId, name: input.fields.name,
                description: input.fields.description, brand: input.fields.brand, model: input.fields.model,
                purchasedOn: input.fields.purchasedOn, photoId: input.photoId, createdAt: now, updatedAt: now,
                version: 1, quantity: input.fields.quantity, restockLimit: input.fields.restockLimit)
            householdItems[input.householdId, default: []].append(item)
            requests[input.requestId] = (input.fields, input.photoId, item.id)
            return item
        }

        func update(_ input: UpdateItemInput, householdID: UUID) throws -> Item {
            let current = try item(id: input.id, householdID: householdID)
            guard current.version == input.expectedVersion else { throw InventoryFailure.conflict }
            var fields = current.fields
            if let name = input.fields.name { fields.name = name }
            if let quantity = input.fields.quantity { fields.quantity = quantity }
            if let restockLimit = input.fields.restockLimit { fields.restockLimit = restockLimit }
            if case .set(let value) = input.fields.description { fields.description = value }
            if case .set(let value) = input.fields.brand { fields.brand = value }
            if case .set(let value) = input.fields.model { fields.model = value }
            if case .set(let value) = input.fields.purchasedOn { fields.purchasedOn = value }
            try fields.validate()
            let updated = Item(
                id: current.id, householdId: householdID, name: fields.name, description: fields.description,
                brand: fields.brand, model: fields.model, purchasedOn: fields.purchasedOn, photoId: current.photoId,
                createdAt: current.createdAt, updatedAt: Date(), version: current.version + 1,
                quantity: fields.quantity, restockLimit: fields.restockLimit
            )
            replace(updated, householdID: householdID)
            return updated
        }

        func delete(id: UUID, expectedVersion: Int64, householdID: UUID) throws {
            guard let index = householdItems[householdID]?.firstIndex(where: { $0.id == id }) else { return }
            guard householdItems[householdID]?[index].version == expectedVersion else {
                throw InventoryFailure.conflict
            }
            if let photoID = householdItems[householdID]?[index].photoId { photos[photoID] = nil }
            householdItems[householdID]?.remove(at: index)
        }

        func removePhoto(itemID: UUID, expectedVersion: Int64, householdID: UUID) throws -> Item {
            let current = try item(id: itemID, householdID: householdID)
            guard current.version == expectedVersion else { throw InventoryFailure.conflict }
            guard let photoID = current.photoId else { return current }
            let updated = Item(
                id: current.id, householdId: householdID, name: current.name, description: current.description,
                brand: current.brand, model: current.model, purchasedOn: current.purchasedOn, photoId: nil,
                createdAt: current.createdAt, updatedAt: Date(), version: current.version + 1,
                quantity: current.quantity, restockLimit: current.restockLimit)
            replace(updated, householdID: householdID)
            photos[photoID] = nil
            return updated
        }

        private func replace(_ item: Item, householdID: UUID) {
            guard let index = householdItems[householdID]?.firstIndex(where: { $0.id == item.id }) else { return }
            householdItems[householdID]?[index] = item
        }
    }

    private struct PreviewPhoto {
        let owner: DraftOwner
        let requestID: UUID
        let reservation: PhotoReservation
        var data: Data?
        var ready = false
    }

    /// Only the explicitly labeled offline UI fixture uses this memory-only photo service.
    @MainActor
    final class PreviewPhotoService: PhotoService {
        let owner: DraftOwner
        private let database: PreviewInventoryDatabase
        init(owner: DraftOwner, database: PreviewInventoryDatabase) {
            self.owner = owner
            self.database = database
        }
        func reserve(requestID: UUID) async throws -> PhotoReservation {
            if let existing = database.photos.values.first(where: { $0.owner == owner && $0.requestID == requestID }) {
                return existing.reservation
            }
            let photoID = UUID()
            let reservation = PhotoReservation(
                photoId: photoID,
                objectKey: PhotoReservation.objectKey(
                    householdID: owner.householdID, uploaderID: owner.accountID, photoID: photoID),
                expiresAt: Date().addingTimeInterval(86_400))
            database.photos[photoID] = PreviewPhoto(owner: owner, requestID: requestID, reservation: reservation)
            return reservation
        }
        func upload(_ draft: ImageDraft, to reservation: PhotoReservation) async throws {
            try reservation.validate(owner: owner)
            guard draft.owner == owner, database.photos[reservation.photoId]?.owner == owner else {
                throw PhotoFailure.forbidden
            }
            try draft.validateStorage()
            database.photos[reservation.photoId]?.data = draft.jpegData
        }
        func complete(_ reservation: PhotoReservation) async throws {
            guard database.photos[reservation.photoId]?.owner == owner else { throw PhotoFailure.notFound }
            guard database.photos[reservation.photoId]?.data != nil else { throw PhotoFailure.uploadIncomplete }
            database.photos[reservation.photoId]?.ready = true
        }
        func download(photoID: UUID) async throws -> Data {
            guard let photo = database.photos[photoID], photo.owner.householdID == owner.householdID,
                photo.ready, database.items(householdID: owner.householdID).contains(where: { $0.photoId == photoID }),
                let data = photo.data
            else { throw PhotoFailure.notFound }
            return data
        }
        func discard(photoID: UUID) async throws {
            guard database.photos[photoID]?.owner == owner else { throw PhotoFailure.notFound }
            guard !database.items(householdID: owner.householdID).contains(where: { $0.photoId == photoID }) else {
                throw PhotoFailure.conflict
            }
            database.photos[photoID] = nil
        }
    }

    actor PreviewDraftDatabase {
        private var drafts: [DraftOwner: TextDraft] = [:]
        private var photos: [DraftOwner: ImageDraft] = [:]
        func load(owner: DraftOwner) -> TextDraft? { drafts[owner] }
        func save(_ draft: TextDraft) { drafts[draft.owner] = draft }
        func clear(owner: DraftOwner) {
            drafts[owner] = nil
            photos[owner] = nil
        }
        func loadPhoto(owner: DraftOwner) -> ImageDraft? { photos[owner] }
        func savePhoto(_ photo: ImageDraft) { photos[photo.owner] = photo }
        func clearPhoto(owner: DraftOwner) { photos[owner] = nil }
    }

    actor PreviewDraftStorage: DraftStorage, ImageDraftStorage {
        nonisolated let owner: DraftOwner
        private let database: PreviewDraftDatabase
        init(owner: DraftOwner, database: PreviewDraftDatabase = PreviewDraftDatabase()) {
            self.owner = owner
            self.database = database
        }
        func load() async -> TextDraft? { await database.load(owner: owner) }
        func save(_ draft: TextDraft) async { await database.save(draft) }
        func clear() async { await database.clear(owner: owner) }
        func loadImageDraft() async -> ImageDraft? { await database.loadPhoto(owner: owner) }
        func saveImageDraft(_ draft: ImageDraft) async throws {
            guard draft.owner == owner else { throw DraftStorageFailure.invalidData }
            try draft.validateStorage()
            await database.savePhoto(draft)
        }
        func clearImageDraft() async { await database.clearPhoto(owner: owner) }
    }
#endif
