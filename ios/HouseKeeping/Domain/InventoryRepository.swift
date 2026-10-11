import Foundation

enum InventoryFailure: Error, Equatable, Sendable {
    case validation, unauthenticated, forbidden, notFound, conflict, photoNotReady, protectedStorage, invalidResponse,
        unavailable
}

struct ItemQuery: Encodable, Equatable, Sendable {
    let householdId: UUID
    var query: String
    var limit: Int = 50
    var offset: Int = 0

    func validate() throws {
        guard query.unicodeScalars.count <= 200, !query.utf8.contains(0),
            query.split(whereSeparator: \.isWhitespace).count <= 8,
            (1...100).contains(limit), (0...10000).contains(offset)
        else { throw InventoryFailure.validation }
    }
}

struct ItemPage: Decodable, Equatable, Sendable {
    let data: [Item]
    let nextOffset: Int?
}

struct CreateItemInput: Encodable, Equatable, Sendable {
    let householdId: UUID
    /// The draft owns this ID; reuse the exact input after an uncertain save result.
    let requestId: UUID
    let fields: ItemFields
    let photoId: UUID?

    init(householdId: UUID, requestId: UUID, fields: ItemFields, photoId: UUID? = nil) {
        self.householdId = householdId
        self.requestId = requestId
        self.fields = fields
        self.photoId = photoId
    }

    private enum CodingKeys: String, CodingKey { case householdId, requestId, photoId }

    func encode(to encoder: any Encoder) throws {
        try fields.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(householdId, forKey: .householdId)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(photoId, forKey: .photoId)
    }
}

struct UpdateItemInput: Encodable, Equatable, Sendable {
    let id: UUID
    let expectedVersion: Int64
    let fields: ItemPatch
}

@MainActor
protocol InventoryRepository: Sendable {
    func search(_ query: ItemQuery) async throws -> ItemPage
    func get(id: UUID) async throws -> Item
    func create(_ input: CreateItemInput) async throws -> Item
    func update(_ input: UpdateItemInput) async throws -> Item
    func delete(id: UUID, expectedVersion: Int64) async throws
    /// Keeps the purchase. A version conflict requires refreshing before another explicit attempt.
    func removePhoto(itemID: UUID, expectedVersion: Int64) async throws -> Item
}
