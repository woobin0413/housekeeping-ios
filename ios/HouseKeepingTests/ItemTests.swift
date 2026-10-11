import Foundation
import Testing

@testable import HouseKeeping

struct ItemTests {
    @Test func stockValuesDefaultValidateAndEncodeZero() throws {
        let legacy = try JSONDecoder().decode(ItemFields.self, from: Data(#"{"name":"Soap"}"#.utf8))
        #expect(legacy.quantity == 1)
        #expect(legacy.restockLimit == 1)
        for quantity in [0, 1, 24, 2_147_483_647] {
            let fields = ItemFields(name: "Soap", quantity: quantity, restockLimit: quantity)
            try fields.validate()
            #expect(try JSONDecoder().decode(ItemFields.self, from: JSONEncoder().encode(fields)) == fields)
            try ItemPatch(quantity: quantity, restockLimit: quantity).validate()
        }
        for quantity in [-1, 2_147_483_648] {
            #expect(throws: InventoryFailure.validation) { try ItemFields(name: "Soap", quantity: quantity).validate() }
            #expect(throws: InventoryFailure.validation) { try ItemPatch(quantity: quantity).validate() }
            #expect(throws: InventoryFailure.validation) {
                try ItemFields(name: "Soap", restockLimit: quantity).validate()
            }
            #expect(throws: InventoryFailure.validation) { try ItemPatch(restockLimit: quantity).validate() }
        }
        let data = try JSONEncoder().encode(ItemPatch(quantity: 0, restockLimit: 2))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(json == ["quantity": 0, "restockLimit": 2])
        for invalid in [
            #"{"name":"Soap","quantity":null}"#, #"{"name":"Soap","quantity":1.5}"#,
            #"{"name":"Soap","restockLimit":null}"#, #"{"name":"Soap","restockLimit":1.5}"#,
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(ItemFields.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test func stockValuesSurviveDraftRecoveryAndConflictReview() throws {
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let base = Item(
            id: UUID(), householdId: owner.householdID, name: "Soap", description: nil, brand: nil,
            model: nil, purchasedOn: nil, photoId: nil, createdAt: .distantPast, updatedAt: .distantPast,
            version: 1, quantity: 3, restockLimit: 1)
        var draft = TextDraft(owner: owner, fields: base.fields, baseItem: base)
        draft.fields.quantity = 0
        draft.fields.restockLimit = 2
        #expect(draft.patch == ItemPatch(quantity: 0, restockLimit: 2))
        let restored = try JSONDecoder().decode(TextDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored == draft)
        var latest = base
        latest.quantity = 8
        latest.restockLimit = 4
        let kept = draft.rebased(on: latest, keepingChanges: true).fields
        #expect(kept.quantity == 0 && kept.restockLimit == 2)
        let accepted = draft.rebased(on: latest, keepingChanges: false).fields
        #expect(accepted.quantity == 8 && accepted.restockLimit == 4)
        draft.fields = base.fields
        draft.fields.name = "Hand soap"
        let merged = draft.rebased(on: latest, keepingChanges: true).fields
        #expect(merged.quantity == 8 && merged.restockLimit == 4)

        var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        oldJSON.removeValue(forKey: "quantity")
        oldJSON.removeValue(forKey: "restockLimit")
        let oldItem = try JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        #expect(oldItem.quantity == 1 && oldItem.restockLimit == 1 && oldItem.needsRestock)
        #expect(!base.needsRestock)
    }

    @Test func dateOnlyValidatesCalendarWithoutTimeZoneConversion() throws {
        for value in ["2024-02-29", "2000-02-29", "2026-09-09", "0001-01-01", "9999-12-31"] {
            let date = try PurchaseDate(value)
            #expect(date.rawValue == value)
            #expect(try JSONDecoder().decode(PurchaseDate.self, from: JSONEncoder().encode(date)) == date)
        }
        for value in [
            "2025-02-29", "1900-02-29", "2026-04-31", "0000-01-01", "2026-13-01", "2026-01-00", "26-01-01", "2026-9-09",
            "2026-09-09Z",
        ] {
            #expect(throws: InventoryFailure.validation) { try PurchaseDate(value) }
        }
    }

    @Test func patchDistinguishesUnchangedAndClear() throws {
        let patch = ItemPatch(name: "Kettle", description: .set(nil), purchasedOn: .set(try PurchaseDate("2026-09-09")))
        let data = try JSONEncoder().encode(patch)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["name"] as? String == "Kettle")
        #expect(json["description"] is NSNull)
        #expect(json["brand"] == nil)
        #expect(json["model"] == nil)
        #expect(json["purchasedOn"] as? String == "2026-09-09")
        #expect(throws: InventoryFailure.validation) { try ItemPatch().validate() }
    }

    @Test func fieldLimitsCountDatabaseCharactersNotGraphemeClusters() throws {
        try ItemFields(name: "\t Kettle\n", description: String(repeating: "a", count: 2000)).validate()
        try ItemFields(name: String(repeating: "é", count: 200)).validate()
        for fields in [
            ItemFields(name: " \n\t"), ItemFields(name: String(repeating: "a", count: 201)),
            ItemFields(name: String(repeating: "e\u{301}", count: 101)),
            ItemFields(name: "Kettle", description: String(repeating: "a", count: 2001)),
            ItemFields(name: "Kettle", brand: String(repeating: "a", count: 101)),
            ItemFields(name: "Kettle", model: "bad\0value"),
        ] {
            #expect(throws: InventoryFailure.validation) { try fields.validate() }
        }
    }

    @Test func queryAndVersionBoundsAreExplicit() throws {
        let household = UUID()
        try ItemQuery(householdId: household, query: "%_\\ kettle", limit: 100, offset: 10000).validate()
        for query in [
            ItemQuery(householdId: household, query: "", limit: 0),
            ItemQuery(householdId: household, query: "", offset: 10001),
            ItemQuery(householdId: household, query: String(repeating: "a", count: 201)),
            ItemQuery(householdId: household, query: "1 2 3 4 5 6 7 8 9"),
        ] {
            #expect(throws: InventoryFailure.validation) { try query.validate() }
        }
        #expect(throws: InventoryFailure.validation) { try ItemVersion.validate(0) }
        #expect(throws: InventoryFailure.validation) { try ItemVersion.validate(9_007_199_254_740_992) }
        try ItemVersion.validate(9_007_199_254_740_991)
    }
}
