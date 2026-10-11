import SwiftUI

struct InventoryView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var store: DemoInventory
    @State private var draft: PurchaseDraft?
    @State private var showsAddOptions = false
    @State private var showsAbout = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    introduction
                    searchField
                    purchaseList
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .foregroundStyle(Palette.ink)
            .toolbar { navigationItems }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: DemoPurchase.self) { purchase in
                PurchaseDetailView(purchase: purchase)
            }
            .safeAreaInset(edge: .bottom) {
                BottomAction {
                    if let announcement = store.announcement {
                        Label(announcement, systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(Palette.action)
                            .accessibilityIdentifier("saveConfirmation")
                    }
                    Button {
                        isSearchFocused = false
                        showsAddOptions = true
                    } label: {
                        Label("Add a purchase", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("addPurchase")
                }
            }
            .confirmationDialog("Add a purchase", isPresented: $showsAddOptions, titleVisibility: .visible) {
                Button("Try sample photo") { draft = PurchaseDraft(isSuggestion: true) }
                Button("Enter manually") { draft = PurchaseDraft(isSuggestion: false) }
            } message: {
                Text("Explore the photo-review flow with a sample, or enter your own details.")
            }
            .sheet(item: $draft) { draft in
                PurchaseReviewView(draft: draft, store: store)
            }
            .alert("Design preview", isPresented: $showsAbout) {
                Button("Got it", role: .cancel) {}
            } message: {
                Text(
                    "Explore sample purchases and photo suggestions. Changes last for this session. Camera capture and private photo storage are available after sign-in; AI recognition is still in development."
                )
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A little order.\nMore home.")
                .font(.largeTitle.weight(.semibold))
                .tracking(-1.2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("inventoryHeading")
            Text("The things you bring home,\nall in one place.")
                .font(.body)
                .foregroundStyle(Palette.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("Search your purchases", text: $store.query)
                .font(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit { isSearchFocused = false }
                .accessibilityIdentifier("inventorySearch")
            if !store.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { store.query = "" }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(Palette.surface)
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Palette.border, lineWidth: 1) }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 16))
    }

    private var purchaseList: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeadingLayout {
                Text(store.query.isEmpty ? "Your purchases" : "Search results")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if !typeSize.isAccessibilitySize { Spacer() }
                Text(store.results.count == 1 ? "1 item" : "\(store.results.count) items")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .accessibilityIdentifier("itemCount")
            }
            if store.purchases.isEmpty && store.query.isEmpty {
                ContentUnavailableView(
                    "Your home starts here", systemImage: "house",
                    description: Text("Add your first purchase to give it a place.")
                )
            } else if store.results.isEmpty {
                ContentUnavailableView.search(text: store.query)
                    .accessibilityIdentifier("emptySearch")
            } else {
                LazyVStack(spacing: 18) {
                    ForEach(store.results) { purchase in
                        NavigationLink(value: purchase) {
                            PurchaseRow(purchase: purchase)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("purchaseRow")
                    }
                }
            }
            Label("A preview of a more organized home", systemImage: "leaf")
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private var sectionHeadingLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }

    @ToolbarContentBuilder
    private var navigationItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 9) {
                Image(systemName: "house.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.action)
                if !typeSize.isAccessibilitySize {
                    Eyebrow(title: "HOUSEKEEPING")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("HouseKeeping")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("About this preview", systemImage: "info.circle") { showsAbout = true }
                .foregroundStyle(Palette.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}

private struct PurchaseRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let purchase: DemoPurchase

    var body: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        layout {
            ProductArtwork(kind: purchase.artwork)
                .frame(width: typeSize.isAccessibilitySize ? nil : 104, height: 110)
            VStack(alignment: .leading, spacing: 7) {
                Text(purchase.name).font(.headline)
                    .foregroundStyle(Palette.ink)
                ItemQuantityLabel(quantity: purchase.quantity, restockLimit: purchase.restockLimit)
                Text(purchase.description)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ItemQuantityLabel: View {
    let quantity: Int
    let restockLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("On hand: \(quantity)")
                .monospacedDigit()
            Text("Restock limit: \(restockLimit)")
                .monospacedDigit()
            if quantity == 0 {
                Label("Out of stock", systemImage: "cart.badge.plus")
            }
            if quantity <= restockLimit {
                Label("Restock now", systemImage: "exclamationmark.circle.fill")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Palette.action)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("itemQuantity")
    }
}

struct ItemQuantityEditor: View {
    @Binding var quantity: Int
    @Binding var restockLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quantity on hand").font(.subheadline.weight(.semibold))
                Stepper(value: $quantity, in: ItemQuantity.range) {
                    Text(quantity, format: .number).monospacedDigit()
                }
                .accessibilityLabel("Quantity on hand")
                .accessibilityValue(quantity.formatted())
                .accessibilityIdentifier("itemQuantityStepper")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Restock limit").font(.subheadline.weight(.semibold))
                Stepper(value: $restockLimit, in: ItemQuantity.range) {
                    Text(restockLimit, format: .number).monospacedDigit()
                }
                .accessibilityLabel("Restock limit")
                .accessibilityValue(restockLimit.formatted())
                .accessibilityIdentifier("itemRestockLimitStepper")
            }
            Text(statusMessage)
                .font(.footnote).foregroundStyle(Palette.secondary)
        }
    }

    private var statusMessage: String {
        if quantity == 0 { return "Out of stock · restock now." }
        if quantity <= restockLimit { return "At or below the limit · restock now." }
        return "Restock when the quantity reaches \(restockLimit)."
    }
}

#Preview("Inventory") {
    InventoryView(store: DemoInventory())
}

#Preview("Inventory · dark") {
    InventoryView(store: DemoInventory()).preferredColorScheme(.dark)
}

#Preview("Inventory · accessible") {
    InventoryView(store: DemoInventory()).environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Inventory · empty") {
    InventoryView(store: DemoInventory(purchases: []))
}
