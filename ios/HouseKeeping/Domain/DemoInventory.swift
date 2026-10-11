import Foundation
import Observation

enum Artwork: String, Hashable {
    case kettle, lamp, cups, plant, none
}

struct DemoPurchase: Identifiable, Hashable {
    let id: UUID
    var name: String
    var description: String
    var brand: String
    var model: String
    var artwork: Artwork
    var quantity: Int
    var restockLimit: Int

    init(
        id: UUID = UUID(), name: String, description: String,
        brand: String = "", model: String = "", artwork: Artwork, quantity: Int = 1, restockLimit: Int = 1
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.brand = brand
        self.model = model
        self.artwork = artwork
        self.quantity = quantity
        self.restockLimit = restockLimit
    }

    static let samples: [DemoPurchase] = [
        .init(name: "Table lamp", description: "A soft glow for the reading corner.", artwork: .lamp),
        .init(name: "Everyday mugs", description: "A pair of cream ceramic coffee mugs.", artwork: .cups, quantity: 2),
        .init(name: "Olive planter", description: "Terracotta pot with a little greenery.", artwork: .plant),
    ]

    static let suggestion = DemoPurchase(
        name: "Electric kettle",
        description: "Matte black electric kettle with a curved spout and a wooden handle.",
        artwork: .kettle
    )
}

@MainActor
@Observable
final class DemoInventory {
    private(set) var purchases: [DemoPurchase]
    private(set) var results: [DemoPurchase]
    var query = "" { didSet { filterPurchases() } }
    var announcement: String?

    init(purchases: [DemoPurchase] = DemoPurchase.samples) {
        self.purchases = purchases
        results = purchases
    }

    func add(_ purchase: DemoPurchase) {
        purchases.insert(purchase, at: 0)
        query = ""
        announcement = "Purchase saved"
    }

    private func filterPurchases() {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        results = purchases.filter { purchase in
            let text = [purchase.name, purchase.description, purchase.brand, purchase.model].joined(separator: " ")
            return tokens.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }
}

@MainActor
@Observable
final class PurchaseDraft: Identifiable {
    let id = UUID()
    let isSuggestion: Bool
    let artwork: Artwork
    private let initialName: String
    private let initialDescription: String
    var name: String
    var description: String
    var brand = ""
    var model = ""
    var quantity = 1
    var restockLimit = 1

    init(isSuggestion: Bool) {
        self.isSuggestion = isSuggestion
        let sample = DemoPurchase.suggestion
        artwork = isSuggestion ? .kettle : .none
        name = isSuggestion ? sample.name : ""
        description = isSuggestion ? sample.description : ""
        initialName = isSuggestion ? sample.name : ""
        initialDescription = isSuggestion ? sample.description : ""
    }

    var hasChanges: Bool {
        name != initialName || description != initialDescription || !brand.isEmpty || !model.isEmpty || quantity != 1
            || restockLimit != 1
    }

    var isValid: Bool {
        let count = name.trimmingCharacters(in: .whitespacesAndNewlines).count
        return (1...200).contains(count) && description.count <= 2_000 && brand.count <= 100 && model.count <= 100
            && ItemQuantity.range.contains(quantity) && ItemQuantity.range.contains(restockLimit)
    }

    func purchase() -> DemoPurchase {
        DemoPurchase(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            brand: brand.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            artwork: artwork, quantity: quantity, restockLimit: restockLimit
        )
    }
}
