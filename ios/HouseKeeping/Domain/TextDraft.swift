import Foundation

struct DraftOwner: Codable, Hashable, Sendable {
    let accountID: UUID
    let householdID: UUID
}

enum DraftStorageFailure: Error, Equatable { case unavailable, invalidData, tooLarge }

protocol DraftStorage: Sendable {
    var owner: DraftOwner { get }
    func load() async throws -> TextDraft?
    func save(_ draft: TextDraft) async throws
    func clear() async throws
}

struct TextDraft: Codable, Equatable, Identifiable, Sendable {
    enum Phase: Codable, Equatable, Sendable {
        case editing, submitting
        case acknowledged(Item)
    }
    let id: UUID
    let owner: DraftOwner
    var fields: ItemFields
    var baseItem: Item?
    var photoId: UUID?
    var rejectedPhotoId: UUID?
    var phase: Phase = .editing

    init(id: UUID = UUID(), owner: DraftOwner, fields: ItemFields, baseItem: Item? = nil) {
        self.id = id
        self.owner = owner
        self.fields = fields
        self.baseItem = baseItem
    }

    func validateStorage() throws {
        if let baseItem {
            guard baseItem.householdId == owner.householdID, photoId == nil, rejectedPhotoId == nil else {
                throw DraftStorageFailure.invalidData
            }
            try baseItem.fields.validate()
            try ItemVersion.validate(baseItem.version)
        }
        switch phase {
        case .editing: break  // Incomplete/invalid forms must also survive relaunch.
        case .submitting: try fields.validate()
        case .acknowledged(let item):
            guard item.householdId == owner.householdID, baseItem == nil || baseItem?.id == item.id else {
                throw DraftStorageFailure.invalidData
            }
            try item.fields.validate()
            try ItemVersion.validate(item.version)
        }
    }

    var patch: ItemPatch {
        guard let baseItem else { return ItemPatch() }
        return ItemPatch(
            name: fields.name == baseItem.name ? nil : fields.name,
            description: fields.description == baseItem.description ? .unchanged : .set(fields.description),
            brand: fields.brand == baseItem.brand ? .unchanged : .set(fields.brand),
            model: fields.model == baseItem.model ? .unchanged : .set(fields.model),
            purchasedOn: fields.purchasedOn == baseItem.purchasedOn ? .unchanged : .set(fields.purchasedOn),
            quantity: fields.quantity == baseItem.quantity ? nil : fields.quantity,
            restockLimit: fields.restockLimit == baseItem.restockLimit ? nil : fields.restockLimit)
    }

    func rebased(on latest: Item, keepingChanges: Bool) -> TextDraft {
        var result = self
        result.baseItem = latest
        result.fields = latest.fields
        if keepingChanges {
            let changes = patch
            if let name = changes.name { result.fields.name = name }
            if let quantity = changes.quantity { result.fields.quantity = quantity }
            if let restockLimit = changes.restockLimit { result.fields.restockLimit = restockLimit }
            if case .set(let value) = changes.description { result.fields.description = value }
            if case .set(let value) = changes.brand { result.fields.brand = value }
            if case .set(let value) = changes.model { result.fields.model = value }
            if case .set(let value) = changes.purchasedOn { result.fields.purchasedOn = value }
        }
        result.phase = .editing
        return result
    }
}
