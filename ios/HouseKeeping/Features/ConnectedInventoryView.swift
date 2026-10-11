import SwiftUI

/// The connected read flow is separate from the explicitly labeled, session-only design demo.
struct ConnectedInventoryView: View {
    let store: InventoryStore
    let connection: AppConnection
    @State private var showsAccount = false
    @State private var editor: ConnectedEditorPresentation?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A little order.\nMore home.")
                            .font(.largeTitle.weight(.semibold)).tracking(-1.2)
                            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("connectedInventoryHeading")
                        Text("The things you bring home, all in one shared place.")
                            .foregroundStyle(Palette.secondary)
                    }
                    ConnectedSearchField(store: store)
                    ConnectedPurchaseList(store: store)
                    Text(developmentStatus)
                        .font(.footnote).foregroundStyle(Palette.secondary)
                        .accessibilityIdentifier("inventoryDevelopmentStatus")
                    if let draft = store.drafts.draft {
                        ConnectedDraftBanner(draft: draft) { editor = .init(id: draft.id) }
                    }
                    if store.drafts.storageFailure != nil {
                        Text("Your local draft couldn’t be opened. It has not been discarded.").font(.footnote)
                        Button("Retry draft recovery") { Task { await store.drafts.restore() } }
                            .frame(minHeight: 44)
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await store.refresh() }
            .background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Your shared home").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                BottomAction {
                    Button(action: openDraft) {
                        Label(
                            store.drafts.draft == nil ? "Add a purchase" : "Continue purchase draft",
                            systemImage: store.drafts.draft == nil ? "plus" : "square.and.pencil")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!store.drafts.hasLoaded || store.drafts.storageFailure != nil)
                    .accessibilityIdentifier("addPurchase")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsAccount = true
                    } label: {
                        Image(systemName: "person.crop.circle").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Account")
                    .accessibilityIdentifier("inventoryAccount")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ConnectedPurchaseDetail(store: store, id: id, editor: $editor)
            }
            .sheet(isPresented: $showsAccount) {
                ConnectedAccountSheet(connection: connection)
            }
            .sheet(item: $editor) { presentation in
                ConnectedPurchaseEditorView(store: store, draftID: presentation.id)
            }
        }
    }

    private func openDraft() {
        if let draft = store.drafts.draft {
            editor = .init(id: draft.id)
        } else if store.beginDraft(), let draft = store.drafts.draft {
            editor = .init(id: draft.id)
        }
    }

    private var developmentStatus: String {
        guard store.photos != nil else {
            return "Purchases are shared with your household. Photo drafts stay on this iPhone in this preview."
        }
        guard store.recognitions != nil else {
            return
                "Saved purchases and photos are shared with your household. Unsaved drafts stay private. "
                + "AI suggestions are currently disabled."
        }
        return
            "Saved purchases and photos are shared with your household. Unsaved drafts stay private. "
            + "Photo suggestions require review before saving."
    }
}

struct ConnectedEditorPresentation: Identifiable, Equatable {
    let id: UUID
}

private struct ConnectedDraftBanner: View {
    let draft: TextDraft
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Draft saved on this iPhone", systemImage: "square.and.pencil")
                .font(.subheadline.weight(.semibold))
            Text(draft.fields.name.isEmpty ? "Untitled purchase" : draft.fields.name)
                .foregroundStyle(Palette.secondary)
            Button("Continue editing", action: open)
                .frame(minHeight: 44)
                .accessibilityIdentifier("continueInventoryDraft")
        }
        .padding(16)
        .background(Palette.sage, in: .rect(cornerRadius: 16))
    }
}

private struct ConnectedSearchField: View {
    let store: InventoryStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("Search your purchases", text: Binding(get: { store.query }, set: { store.setQuery($0) }))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search).focused($focused).onSubmit { focused = false }
                .accessibilityIdentifier("inventorySearch")
            if !store.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { store.setQuery("") }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
        }
        .foregroundStyle(Palette.secondary).padding(.horizontal, 16).frame(minHeight: 56)
        .background(Palette.surface, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border) }
    }
}

private struct ConnectedPurchaseList: View {
    let store: InventoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.query.isEmpty ? "Your purchases" : "Search results")
                .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let failure = store.failure {
                Text(failure.message).accessibilityIdentifier("inventoryError")
                Button("Retry") { Task { await store.refresh() } }.frame(minHeight: 44)
            } else if store.items.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    store.query.isEmpty ? "Your home starts here" : "No matching purchases",
                    systemImage: store.query.isEmpty ? "house" : "magnifyingglass",
                    description: Text(
                        store.query.isEmpty
                            ? "Saved purchases will appear here." : "Try a different name or description.")
                )
                .accessibilityIdentifier("emptyInventory")
            }
            LazyVStack(spacing: 18) {
                ForEach(store.items) { item in
                    NavigationLink(value: item.id) { ConnectedPurchaseRow(item: item, store: store) }
                        .buttonStyle(.plain).accessibilityIdentifier("connectedPurchaseRow")
                }
            }
            if store.isLoading { ProgressView("Loading purchases…").accessibilityIdentifier("inventoryLoading") }
            if store.nextOffset != nil {
                Button("Load more") { Task { await store.loadMore() } }
                    .frame(minHeight: 44).disabled(store.isLoading)
            }
            if let updated = store.lastUpdated {
                Text("Refreshed \(updated, format: .dateTime.hour().minute())")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
        }
    }
}

private struct ConnectedPurchaseRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: Item
    let store: InventoryStore
    var body: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        layout {
            ConnectedPurchaseThumbnail(item: item, store: store)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.name).font(.headline)
                ItemQuantityLabel(quantity: item.quantity, restockLimit: item.restockLimit)
                if let description = item.description {
                    Text(description).font(.subheadline).foregroundStyle(Palette.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectedPurchaseThumbnail: View {
    @State private var model = PrivatePhotoModel()
    let item: Item
    let store: InventoryStore

    private struct Request: Equatable {
        let photoID: UUID?
        let generation: UUID
    }

    var body: some View {
        Group {
            if let image = model.image, item.photoId != nil {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFill()
            } else if model.isLoading {
                ProgressView()
            } else {
                Image(systemName: item.photoId == nil ? "shippingbox" : "photo")
                    .font(.title2).foregroundStyle(Palette.action)
            }
        }
        .frame(width: 64, height: 64)
        .background(Palette.sage)
        .compositingGroup().clipShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            model.isLoading ? "Loading purchase photo" : (model.image == nil ? "Photo unavailable" : "Purchase photo")
        )
        .accessibilityHidden(item.photoId == nil)
        .accessibilityIdentifier(model.image == nil ? "purchaseThumbnailPlaceholder" : "purchaseThumbnail")
        .task(id: Request(photoID: item.photoId, generation: store.thumbnailGeneration)) {
            await store.loadThumbnail(for: item, into: model)
        }
        .onDisappear { store.releaseThumbnail(model) }
    }
}

private struct ConnectedPurchaseDetail: View {
    @Environment(\.dismiss) private var dismiss
    let store: InventoryStore
    let id: UUID
    @Binding var editor: ConnectedEditorPresentation?
    @State private var confirmsDelete = false
    @State private var photoToRemove: Item?
    @State private var isDeleting = false

    var body: some View {
        ScrollView {
            if let item = store.detail, item.id == id {
                VStack(alignment: .leading, spacing: 20) {
                    Eyebrow(title: "AT HOME")
                    Text(item.name).font(.largeTitle.weight(.semibold)).accessibilityIdentifier("connectedDetailName")
                    ItemQuantityLabel(quantity: item.quantity, restockLimit: item.restockLimit)
                    if item.photoId != nil {
                        ConnectedDetailPhoto(model: store.detailPhoto) {
                            Task { await store.loadDetail(id: id) }
                        }
                        Button("Remove photo", role: .destructive) { photoToRemove = item }
                            .frame(minHeight: 44)
                            .disabled(
                                isDeleting || store.isRemovingPhoto || store.drafts.draft != nil
                                    || store.photoDraft?.needsDiscardConfirmation == true
                            )
                            .accessibilityIdentifier("removePurchasePhoto")
                        if store.isRemovingPhoto { ProgressView("Removing photo…") }
                    }
                    if let description = item.description { Text(description).foregroundStyle(Palette.secondary) }
                    if let brand = item.brand { LabeledContent("Brand", value: brand) }
                    if let model = item.model { LabeledContent("Model", value: model) }
                    if let date = item.purchasedOn { LabeledContent("Purchased on", value: date.rawValue) }
                    Text("Shared with your household. Pull to refresh for the latest saved details.")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                    if let failure = store.mutationFailure {
                        Text(failure.message).foregroundStyle(.red)
                            .accessibilityIdentifier("inventoryMutationError")
                    }
                    ConnectedDetailActions(
                        hasDraft: store.drafts.draft != nil || store.photoDraft?.needsDiscardConfirmation == true,
                        isDeleting: isDeleting, isRemovingPhoto: store.isRemovingPhoto,
                        edit: { openEditor(item) }, delete: { confirmsDelete = true })
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            } else if store.isLoadingDetail {
                ProgressView("Loading purchase…")
            } else {
                ContentUnavailableView(
                    "Purchase unavailable", systemImage: "shippingbox",
                    description: Text(store.detailFailure?.message ?? "Return to inventory and refresh your purchases.")
                )
                Button("Retry purchase") { Task { await store.loadDetail(id: id) } }.frame(minHeight: 44)
            }
        }
        .task(id: id) { await store.loadDetail(id: id) }
        .refreshable { await store.loadDetail(id: id) }
        .background(Palette.background).foregroundStyle(Palette.ink)
        .navigationTitle("Purchase details").navigationBarTitleDisplayMode(.inline)
        .alert("Delete this purchase?", isPresented: $confirmsDelete) {
            Button("Delete purchase", role: .destructive) { deleteCurrentItem() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will disappear from the shared household inventory. This can’t be undone in the app.")
        }
        .alert(
            "Remove this shared photo?",
            isPresented: Binding(
                get: { photoToRemove != nil }, set: { if !$0 { photoToRemove = nil } }
            ), presenting: photoToRemove
        ) { item in
            Button("Remove photo", role: .destructive) {
                Task { _ = await store.removePhoto(from: item, confirmed: true) }
            }.accessibilityIdentifier("confirmRemovePurchasePhoto")
            Button("Keep photo", role: .cancel) {}
        } message: { _ in
            Text(
                "The photo will be removed for both household members. The purchase details and original library photo will stay unchanged."
            )
        }
    }

    private func openEditor(_ item: Item) {
        if let draft = store.drafts.draft {
            editor = .init(id: draft.id)
        } else if store.beginDraft(item: store.photoDraft?.needsDiscardConfirmation == true ? nil : item),
            let draft = store.drafts.draft
        {
            editor = .init(id: draft.id)
        }
    }

    private func deleteCurrentItem() {
        guard let item = store.detail, item.id == id else { return }
        isDeleting = true
        Task {
            let deleted = await store.delete(item, confirmed: true)
            isDeleting = false
            if deleted { dismiss() }
        }
    }
}

private struct ConnectedDetailPhoto: View {
    let model: PrivatePhotoModel
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Shared purchase photo")
                    .accessibilityIdentifier("sharedPurchasePhoto")
            } else if model.isLoading {
                ProgressView("Loading private photo…")
            } else {
                Label("Photo unavailable", systemImage: "photo")
                if let failure = model.failure {
                    Text(failure.message).font(.footnote).foregroundStyle(Palette.secondary)
                }
                Button("Retry photo", action: retry).frame(minHeight: 44)
                    .accessibilityIdentifier("retrySharedPhoto")
            }
        }
    }
}

private struct ConnectedDetailActions: View {
    let hasDraft: Bool
    let isDeleting: Bool
    let isRemovingPhoto: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasDraft {
                Text("Finish or discard the current local draft before deleting a purchase.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            Button(hasDraft ? "Continue current draft" : "Edit purchase", action: edit)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isDeleting || isRemovingPhoto)
                .accessibilityIdentifier("editPurchase")
            Button("Delete purchase", role: .destructive, action: delete)
                .frame(minHeight: 44)
                .disabled(isDeleting || isRemovingPhoto || hasDraft)
                .accessibilityIdentifier("deletePurchase")
            if isDeleting { ProgressView("Deleting purchase…") }
        }
    }
}

private struct ConnectedAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let connection: AppConnection
    var body: some View {
        NavigationStack {
            AccountView(connection: connection)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension InventoryFailure {
    var message: String {
        switch self {
        case .validation:
            "Check your search or purchase details and try again. Search supports up to eight words and 200 characters."
        case .unauthenticated: "Your session has ended. Check your account connection to continue."
        case .forbidden: "Your household access needs to be checked before continuing."
        case .notFound: "This purchase or household is no longer available."
        case .conflict: "This purchase changed. Review the latest details before trying again."
        case .photoNotReady: "The photo upload is no longer ready. Your draft is safe; retry to upload a fresh copy."
        case .protectedStorage: "Unlock this iPhone and retry to access protected storage."
        case .invalidResponse, .unavailable: "We couldn’t load your purchases. Check your connection and retry."
        }
    }
}
