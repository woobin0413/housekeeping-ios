import Foundation

/// A calendar date, never a midnight instant that can move across time zones.
struct PurchaseDate: Codable, Hashable, Sendable {
    let rawValue: String

    init(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
            bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
            let year = Int(value.prefix(4)), let month = Int(value.dropFirst(5).prefix(2)),
            let day = Int(value.suffix(2)), (1...9999).contains(year), (1...12).contains(month)
        else { throw InventoryFailure.validation }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { throw InventoryFailure.validation }
        rawValue = value
    }

    init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct Item: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let householdId: UUID
    let name: String
    let description: String?
    let brand: String?
    let model: String?
    let purchasedOn: PurchaseDate?
    let photoId: UUID?
    let createdAt: Date
    let updatedAt: Date
    let version: Int64
    var quantity: Int = 1
    var restockLimit: Int = 1

    var needsRestock: Bool { quantity <= restockLimit }

    var fields: ItemFields {
        ItemFields(
            name: name, description: description, brand: brand, model: model, purchasedOn: purchasedOn,
            quantity: quantity, restockLimit: restockLimit)
    }
}

struct ItemFields: Codable, Equatable, Sendable {
    var name: String
    var description: String? = nil
    var brand: String? = nil
    var model: String? = nil
    var purchasedOn: PurchaseDate? = nil
    var quantity: Int = 1
    var restockLimit: Int = 1

    func validate() throws {
        try ItemValidation.name(name)
        try ItemValidation.text(description, maximum: 2000)
        try ItemValidation.text(brand, maximum: 100)
        try ItemValidation.text(model, maximum: 100)
        try ItemQuantity.validate(quantity)
        try ItemQuantity.validate(restockLimit)
    }
}

/// `.unchanged` omits the key; `.set(nil)` explicitly clears a nullable field.
enum ItemFieldChange<Value: Encodable & Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value?)
}

struct ItemPatch: Encodable, Equatable, Sendable {
    var name: String? = nil
    var description: ItemFieldChange<String> = .unchanged
    var brand: ItemFieldChange<String> = .unchanged
    var model: ItemFieldChange<String> = .unchanged
    var purchasedOn: ItemFieldChange<PurchaseDate> = .unchanged
    var quantity: Int? = nil
    var restockLimit: Int? = nil

    func validate() throws {
        guard
            name != nil || description != .unchanged || brand != .unchanged
                || model != .unchanged || purchasedOn != .unchanged || quantity != nil || restockLimit != nil
        else { throw InventoryFailure.validation }
        if let name { try ItemValidation.name(name) }
        if case .set(let value) = description { try ItemValidation.text(value, maximum: 2000) }
        if case .set(let value) = brand { try ItemValidation.text(value, maximum: 100) }
        if case .set(let value) = model { try ItemValidation.text(value, maximum: 100) }
        if let quantity { try ItemQuantity.validate(quantity) }
        if let restockLimit { try ItemQuantity.validate(restockLimit) }
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, brand, model, purchasedOn, quantity, restockLimit
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(quantity, forKey: .quantity)
        try container.encodeIfPresent(restockLimit, forKey: .restockLimit)
        try encode(description, to: &container, key: .description)
        try encode(brand, to: &container, key: .brand)
        try encode(model, to: &container, key: .model)
        try encode(purchasedOn, to: &container, key: .purchasedOn)
    }

    private func encode<Value>(
        _ change: ItemFieldChange<Value>, to container: inout KeyedEncodingContainer<CodingKeys>, key: CodingKeys
    ) throws {
        if case .set(let value) = change {
            if let value { try container.encode(value, forKey: key) } else { try container.encodeNil(forKey: key) }
        }
    }
}

enum ItemQuantity {
    static let range = 0...2_147_483_647

    static func validate(_ value: Int) throws {
        guard range.contains(value) else { throw InventoryFailure.validation }
    }
}

// Older protected drafts have no stock keys. Keep their original meaning of one item and limit one.
extension ItemFields {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        brand = try container.decodeIfPresent(String.self, forKey: .brand)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        purchasedOn = try container.decodeIfPresent(PurchaseDate.self, forKey: .purchasedOn)
        quantity = try container.contains(.quantity) ? container.decode(Int.self, forKey: .quantity) : 1
        restockLimit = try container.contains(.restockLimit) ? container.decode(Int.self, forKey: .restockLimit) : 1
    }
}

extension Item {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        householdId = try container.decode(UUID.self, forKey: .householdId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        brand = try container.decodeIfPresent(String.self, forKey: .brand)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        purchasedOn = try container.decodeIfPresent(PurchaseDate.self, forKey: .purchasedOn)
        photoId = try container.decodeIfPresent(UUID.self, forKey: .photoId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        version = try container.decode(Int64.self, forKey: .version)
        quantity = try container.contains(.quantity) ? container.decode(Int.self, forKey: .quantity) : 1
        restockLimit = try container.contains(.restockLimit) ? container.decode(Int.self, forKey: .restockLimit) : 1
    }
}

enum ItemVersion {
    static func validate(_ value: Int64) throws {
        guard (1...9_007_199_254_740_991).contains(value) else { throw InventoryFailure.validation }
    }
}

private enum ItemValidation {
    static func name(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InventoryFailure.validation }
        try text(trimmed, maximum: 200)
    }

    static func text(_ value: String?, maximum: Int) throws {
        // PostgreSQL char_length counts Unicode scalars, not Swift grapheme clusters.
        guard let value else { return }
        guard value.unicodeScalars.count <= maximum, !value.utf8.contains(0) else { throw InventoryFailure.validation }
    }
}
