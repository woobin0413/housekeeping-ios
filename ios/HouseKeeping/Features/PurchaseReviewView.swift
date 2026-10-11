import SwiftUI

struct PurchaseReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: PurchaseDraft
    let store: DemoInventory
    @State private var showsDiscardConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(title: draft.isSuggestion ? "REVIEW YOUR PHOTO" : "A NEW ADDITION")
                        Text("Make it yours.")
                            .font(.largeTitle.weight(.semibold))
                            .tracking(-1)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if draft.isSuggestion {
                        SamplePhotoHeader()
                    }
                    DraftFields(draft: draft)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .foregroundStyle(Palette.ink)
            .navigationTitle("New purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomAction {
                    Button(action: save) {
                        Label("Save purchase", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!draft.isValid)
                    .accessibilityIdentifier("savePurchase")
                }
            }
            .interactiveDismissDisabled(draft.hasChanges)
            .alert("Discard your changes?", isPresented: $showsDiscardConfirmation) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .tint(Palette.action)
    }

    private func cancel() {
        if draft.hasChanges { showsDiscardConfirmation = true } else { dismiss() }
    }

    private func save() {
        guard draft.isValid else { return }
        store.add(draft.purchase())
        dismiss()
    }
}

private struct SamplePhotoHeader: View {
    var body: some View {
        VStack(spacing: 16) {
            ProductArtwork(kind: .kettle)
                .aspectRatio(1.85, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text("Sample photo")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(red: 0.2, green: 0.27, blue: 0.21))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(0.85), in: Capsule())
                        .padding(14)
                }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Palette.action)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offline sample suggestion").font(.subheadline.weight(.semibold))
                    Text("A design example only. Edit anything below.")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Palette.sage, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }
}

private struct DraftFields: View {
    @Bindable var draft: PurchaseDraft
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case name, description, brand, model }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Item name").font(.subheadline.weight(.semibold))
                TextField("What did you bring home?", text: $draft.name, axis: .vertical)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("Item name")
                    .accessibilityIdentifier("itemName")
                    .fieldSurface()
                if draft.name.count > 200 {
                    Text("Keep the name to 200 characters.").font(.footnote).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Description").font(.subheadline.weight(.semibold))
                TextField("Details to help you find it later", text: $draft.description, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focusedField, equals: .description)
                    .accessibilityLabel("Description")
                    .accessibilityIdentifier("itemDescription")
                    .fieldSurface()
                if draft.description.count > 2_000 {
                    Text("Keep the description to 2,000 characters.").font(.footnote).foregroundStyle(.red)
                }
            }
            ItemQuantityEditor(quantity: $draft.quantity, restockLimit: $draft.restockLimit)
            DisclosureGroup("More details · optional") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Brand").font(.subheadline.weight(.semibold))
                    TextField("Brand", text: $draft.brand)
                        .accessibilityLabel("Brand").accessibilityIdentifier("itemBrand")
                        .focused($focusedField, equals: .brand).fieldSurface()
                    Text("Model").font(.subheadline.weight(.semibold))
                    TextField("Model", text: $draft.model)
                        .accessibilityLabel("Model").accessibilityIdentifier("itemModel")
                        .focused($focusedField, equals: .model).fieldSurface()
                    if draft.brand.count > 100 || draft.model.count > 100 {
                        Text("Keep brand and model to 100 characters each.").font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.top, 12)
            }
            .font(.subheadline)
            .foregroundStyle(Palette.secondary)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }
}

extension View {
    fileprivate func fieldSurface() -> some View {
        self.font(.body)
            .padding(16)
            .background(Palette.surface)
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.border, lineWidth: 1) }
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 14))
    }
}

struct PurchaseDetailView: View {
    let purchase: DemoPurchase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if purchase.artwork != .none {
                    ProductArtwork(kind: purchase.artwork).aspectRatio(1.25, contentMode: .fit)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(title: "AT HOME")
                    Text(purchase.name).font(.largeTitle.weight(.semibold))
                    ItemQuantityLabel(quantity: purchase.quantity, restockLimit: purchase.restockLimit)
                    Text(purchase.description).font(.body).foregroundStyle(Palette.secondary)
                    if !purchase.brand.isEmpty { LabeledContent("Brand", value: purchase.brand) }
                    if !purchase.model.isEmpty { LabeledContent("Model", value: purchase.model) }
                }
                Text("Design preview · saved for this session")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            .padding(24)
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .navigationTitle("Purchase details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Photo review") {
    PurchaseReviewView(draft: PurchaseDraft(isSuggestion: true), store: DemoInventory())
}

#Preview("Manual entry") {
    PurchaseReviewView(draft: PurchaseDraft(isSuggestion: false), store: DemoInventory())
}

#Preview("Photo review · dark") {
    PurchaseReviewView(draft: PurchaseDraft(isSuggestion: true), store: DemoInventory())
        .preferredColorScheme(.dark)
}
