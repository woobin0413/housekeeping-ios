import Foundation
import SwiftUI

struct ConnectedPurchaseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: InventoryStore
    let draftID: UUID
    @State private var showsDiscardConfirmation = false
    @FocusState private var focusedField: Field?

    fileprivate enum Field: Hashable { case name, description, brand, model }

    private var draft: TextDraft? {
        guard store.drafts.draft?.id == draftID else { return nil }
        return store.drafts.draft
    }

    private var canEdit: Bool {
        draft?.phase == .editing && !store.drafts.isSaving && !store.isPreparingPhotoSave
    }

    private var isValid: Bool {
        guard let fields = draft?.fields else { return false }
        do {
            try fields.validate()
            return true
        } catch { return false }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let draft {
                    VStack(alignment: .leading, spacing: 24) {
                        ConnectedEditorHeading(isEditing: draft.baseItem != nil)
                        ConnectedDraftStatus(draft: draft, controller: store.drafts)
                        if draft.baseItem == nil, let photoDraft = store.photoDraft {
                            PhotoImportView(model: photoDraft)
                                .disabled(!canEdit || store.recognitionState.isWorking)
                                .onChange(of: photoDraft.draft?.id) { previous, current in
                                    if previous != current { store.photoDraftChanged() }
                                }
                            if photoDraft.draft != nil, store.photos == nil {
                                Text(
                                    "Your photo is saved on this iPhone. Sharing photos is coming next; keep this draft, or discard its photo to save the purchase as text."
                                )
                                .font(.footnote).foregroundStyle(Palette.secondary)
                            }
                            if let stage = photoDraft.uploadStage {
                                ProgressView(stage.message).accessibilityIdentifier("photoUploadProgress")
                            }
                            if let failure = photoDraft.uploadFailure {
                                Text(failure.message).font(.footnote).foregroundStyle(.red)
                                    .accessibilityIdentifier("photoUploadError")
                            }
                            if photoDraft.draft != nil, store.recognitions != nil {
                                ConnectedRecognitionReview(store: store)
                            }
                        }
                        ConnectedDraftFields(
                            draft: draft, isEnabled: canEdit, focusedField: $focusedField,
                            update: update)
                        if let latest = store.drafts.conflictItem {
                            ConnectedConflictReview(
                                draft: draft, latest: latest,
                                keepChanges: { store.drafts.resolveConflict(keepingChanges: true) },
                                useLatest: { store.drafts.resolveConflict(keepingChanges: false) })
                        }
                    }
                    .padding(24)
                } else {
                    ContentUnavailableView(
                        "Draft closed", systemImage: "checkmark.circle",
                        description: Text("Return to your inventory to continue."))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .foregroundStyle(Palette.ink)
            .navigationTitle(draft?.baseItem == nil ? "New purchase" : "Edit purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsDiscardConfirmation = true }
                        .disabled(store.isPreparingPhotoSave || store.drafts.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Keep draft") {
                        Task { if await store.drafts.flush() { dismiss() } }
                    }
                    .disabled(store.isPreparingPhotoSave || store.drafts.isSaving || store.photoDraft?.isBusy == true)
                    .accessibilityIdentifier("keepPurchaseDraft")
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomAction {
                    if store.drafts.saveFailure == .conflict, store.drafts.conflictItem == nil {
                        Button("Review latest version") { Task { await store.drafts.reviewConflict() } }
                            .frame(minHeight: 44)
                            .disabled(store.drafts.isSaving)
                            .accessibilityIdentifier("reviewInventoryConflict")
                    }
                    Button(action: save) {
                        if store.isPreparingPhotoSave || store.drafts.isSaving {
                            ProgressView(store.drafts.isSaving ? "Saving purchase…" : "Preparing photo save…")
                                .tint(Palette.actionText)
                        } else {
                            Label(saveTitle, systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saveDisabled)
                    .accessibilityIdentifier("connectedSavePurchase")
                }
            }
            .interactiveDismissDisabled(draft != nil)
            .alert("Discard this local draft?", isPresented: $showsDiscardConfirmation) {
                Button("Discard draft", role: .destructive) { discard() }
                    .accessibilityIdentifier("confirmDiscardDraft")
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(discardMessage)
            }
        }
        .tint(Palette.action)
        .accessibilityIdentifier("connectedPurchaseEditor")
        .onDisappear { store.continueManually() }
    }

    private var saveTitle: String {
        guard let phase = draft?.phase else { return "Save purchase" }
        switch phase {
        case .editing: return draft?.baseItem == nil ? "Save purchase" : "Save changes"
        case .submitting: return "Retry save"
        case .acknowledged: return "Finish saving"
        }
    }

    private var saveDisabled: Bool {
        guard draft != nil, !store.isPreparingPhotoSave, !store.drafts.isSaving,
            store.drafts.conflictItem == nil
        else { return true }
        if draft?.phase == .editing, let photo = store.photoDraft {
            if !photo.hasRestored || photo.isBusy || photo.failure == .storage { return true }
            if photo.draft != nil && (store.photos == nil || draft?.baseItem != nil) { return true }
        }
        return draft?.phase == .editing && !isValid
    }

    private var discardMessage: String {
        guard let phase = draft?.phase else { return "The local draft will be removed from this iPhone." }
        switch phase {
        case .editing:
            return
                "Your unsaved text and prepared photo will be removed from this iPhone. The original library photo stays unchanged."
        case .submitting, .acknowledged:
            return
                "This request may already have reached the shared inventory. Discarding removes only the local retry copy."
        }
    }

    private func update(_ fields: ItemFields) {
        _ = store.drafts.edit(fields)
    }

    private func save() {
        focusedField = nil
        Task {
            if await store.saveDraft() != nil { dismiss() }
        }
    }

    private func discard() {
        focusedField = nil
        Task {
            if await store.discardDraft(confirmed: true) { dismiss() }
        }
    }
}

private struct ConnectedRecognitionReview: View {
    let store: InventoryStore

    private var isSample: Bool { store.recognitions?.source == .sample }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isSample ? "Offline sample suggestion" : "Suggest purchase details")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(
                isSample
                    ? "This labeled preview creates a sample suggestion on this iPhone. No photo is sent to an AI provider."
                    : "If you ask for a suggestion, the prepared photo is sent to the configured AI provider. Review and edit every field before saving."
            )
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            recognitionStatus
            if store.recognitionState.isWorking {
                Button("Continue manually") { store.continueManually() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("continueRecognitionManually")
            } else if canRequestRecognition {
                Button(action: recognize) {
                    Label(recognitionButtonTitle, systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.photoDraft?.isBusy == true)
                .accessibilityIdentifier("requestRecognition")
            }
        }
        .padding(16)
        .background(Palette.sage, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var canRequestRecognition: Bool {
        switch store.recognitionState {
        case .suggested, .unrecognized, .failed(.providerRefusal), .failed(.invalidResponse),
            .failed(.quotaExceeded), .failed(.validation), .failed(.notFound):
            false
        default: true
        }
    }

    @ViewBuilder private var recognitionStatus: some View {
        switch store.recognitionState {
        case .idle, .manual:
            EmptyView()
        case .preparing:
            ProgressView("Uploading photo separately…")
                .accessibilityIdentifier("recognitionProgress")
        case .recognizing:
            ProgressView("Looking for one product…")
                .accessibilityIdentifier("recognitionProgress")
        case .suggested(let source):
            Label(
                source == .sample
                    ? "Sample fields are ready to edit." : "AI-suggested fields are ready to edit.",
                systemImage: "pencil"
            )
            .foregroundStyle(Palette.secondary)
            .accessibilityIdentifier("recognitionSuggestionReady")
        case .unrecognized(_, let reason):
            Text(reason.message)
                .foregroundStyle(Palette.secondary)
                .accessibilityIdentifier("recognitionUnrecognized")
        case .failed(let failure):
            Text(failure.message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("recognitionError")
        case .stale:
            Text("Your edits were kept. The late suggestion was not applied.")
                .foregroundStyle(Palette.secondary)
                .accessibilityIdentifier("recognitionStale")
        }
    }

    private var recognitionButtonTitle: String {
        switch store.recognitionState {
        case .stale: return isSample ? "Request sample again" : "Request a new suggestion"
        default: return isSample ? "Try sample suggestion" : "Suggest details with AI"
        }
    }

    private func recognize() {
        Task { await store.requestRecognition() }
    }
}

extension UnrecognizedReason {
    fileprivate var message: String {
        switch self {
        case .multipleProducts: "More than one product was found. Retake with one item or continue manually."
        case .unclearImage: "The product was not clear enough. Retake the photo or continue manually."
        case .noProduct: "No product was found. Choose another photo or continue manually."
        }
    }
}

extension RecognitionFailure {
    fileprivate var message: String {
        switch self {
        case .quotaExceeded: "The recognition limit has been reached for today. Continue manually."
        case .inProgress: "This suggestion is still processing. Continue manually or check again."
        case .retryRequired: "The suggestion took too long or could not finish. Continue manually or try again."
        case .providerRefusal: "No suggestion was returned. Continue manually or choose another photo."
        case .invalidResponse: "The suggestion could not be verified, so it was not applied. Continue manually."
        case .validation, .notFound: "This photo cannot be recognized. Choose another photo or continue manually."
        case .unauthenticated: "Sign in again before requesting a suggestion. Your draft remains on this iPhone."
        case .forbidden: "This photo is no longer available to this account. Your draft remains on this iPhone."
        case .unavailable: "Recognition is unavailable. Continue manually or try again later."
        }
    }
}

private struct ConnectedEditorHeading: View {
    let isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title: isEditing ? "A SHARED PURCHASE" : "A NEW ADDITION")
            Text(isEditing ? "Keep it current." : "Make it yours.")
                .font(.largeTitle.weight(.semibold))
                .tracking(-1)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct ConnectedDraftStatus: View {
    let draft: TextDraft
    let controller: InventoryDraftController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch draft.phase {
            case .editing:
                if controller.isPersisting {
                    Label("Saving draft on this iPhone…", systemImage: "iphone")
                } else {
                    Label("Draft saved on this iPhone", systemImage: "iphone")
                }
            case .submitting:
                Label(
                    "The exact saved request is ready to retry. Fields stay locked until the result is known.",
                    systemImage: "arrow.clockwise")
            case .acknowledged:
                Label(
                    "The server accepted this purchase. Finish saving to clear its local retry copy.",
                    systemImage: "checkmark.circle")
            }
            if let failure = controller.saveFailure {
                Text(failure.message).foregroundStyle(.red).accessibilityIdentifier("connectedSaveError")
            }
            if controller.storageFailure != nil {
                Text("The protected local draft couldn’t be updated. Unlock this iPhone and retry.")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("connectedDraftStorageError")
                if draft.phase == .editing {
                    Button("Retry local draft save") { Task { _ = await controller.flush() } }
                        .frame(minHeight: 44)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondary)
        .accessibilityElement(children: .contain)
    }
}

private struct ConnectedDraftFields: View {
    let draft: TextDraft
    let isEnabled: Bool
    @FocusState.Binding var focusedField: ConnectedPurchaseEditorView.Field?
    let update: (ItemFields) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectedField(label: "Item name", error: nameError) {
                TextField("What did you bring home?", text: requiredText(\.name), axis: .vertical)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("Item name")
                    .accessibilityIdentifier("connectedItemName")
                    .connectedFieldSurface()
            }
            ConnectedField(label: "Description", error: descriptionError) {
                TextField("Details to help you find it later", text: optionalText(\.description), axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focusedField, equals: .description)
                    .accessibilityLabel("Description")
                    .accessibilityIdentifier("connectedItemDescription")
                    .connectedFieldSurface()
            }
            ItemQuantityEditor(
                quantity: Binding(
                    get: { draft.fields.quantity },
                    set: { quantity in
                        var fields = draft.fields
                        fields.quantity = quantity
                        update(fields)
                    }),
                restockLimit: Binding(
                    get: { draft.fields.restockLimit },
                    set: { restockLimit in
                        var fields = draft.fields
                        fields.restockLimit = restockLimit
                        update(fields)
                    }))
            DisclosureGroup("More details · optional") {
                VStack(alignment: .leading, spacing: 16) {
                    ConnectedField(label: "Brand", error: brandError) {
                        TextField("Brand", text: optionalText(\.brand))
                            .focused($focusedField, equals: .brand)
                            .accessibilityLabel("Brand")
                            .accessibilityIdentifier("connectedItemBrand")
                            .connectedFieldSurface()
                    }
                    ConnectedField(label: "Model", error: modelError) {
                        TextField("Model", text: optionalText(\.model))
                            .focused($focusedField, equals: .model)
                            .accessibilityLabel("Model")
                            .accessibilityIdentifier("connectedItemModel")
                            .connectedFieldSurface()
                    }
                    Toggle("Include purchase date", isOn: purchaseDateEnabled)
                    if draft.fields.purchasedOn != nil {
                        DatePicker("Purchased on", selection: purchaseDate, displayedComponents: .date)
                            .accessibilityIdentifier("connectedPurchaseDate")
                    }
                }
                .padding(.top, 12)
            }
            .font(.subheadline)
            .foregroundStyle(Palette.secondary)
        }
        .disabled(!isEnabled)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    private var nameError: String? {
        draft.fields.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter an item name."
            : (draft.fields.name.unicodeScalars.count > 200 ? "Keep the name to 200 characters." : nil)
    }
    private var descriptionError: String? {
        (draft.fields.description?.unicodeScalars.count ?? 0) > 2_000
            ? "Keep the description to 2,000 characters." : nil
    }
    private var brandError: String? {
        (draft.fields.brand?.unicodeScalars.count ?? 0) > 100 ? "Keep the brand to 100 characters." : nil
    }
    private var modelError: String? {
        (draft.fields.model?.unicodeScalars.count ?? 0) > 100 ? "Keep the model to 100 characters." : nil
    }

    private func requiredText(_ keyPath: WritableKeyPath<ItemFields, String>) -> Binding<String> {
        Binding(
            get: { draft.fields[keyPath: keyPath] },
            set: { value in
                var fields = draft.fields
                fields[keyPath: keyPath] = value
                update(fields)
            })
    }

    private func optionalText(_ keyPath: WritableKeyPath<ItemFields, String?>) -> Binding<String> {
        Binding(
            get: { draft.fields[keyPath: keyPath] ?? "" },
            set: { value in
                var fields = draft.fields
                fields[keyPath: keyPath] = value.isEmpty ? nil : value
                update(fields)
            })
    }

    private var purchaseDateEnabled: Binding<Bool> {
        Binding(
            get: { draft.fields.purchasedOn != nil },
            set: { enabled in
                var fields = draft.fields
                fields.purchasedOn = enabled ? PurchaseDateEditor.purchaseDate(from: .now) : nil
                update(fields)
            })
    }

    private var purchaseDate: Binding<Date> {
        Binding(
            get: { PurchaseDateEditor.date(from: draft.fields.purchasedOn) },
            set: { date in
                var fields = draft.fields
                fields.purchasedOn = PurchaseDateEditor.purchaseDate(from: date)
                update(fields)
            })
    }
}

private struct ConnectedField<Content: View>: View {
    let label: String
    let error: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold))
            content
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }
}

private struct ConnectedConflictReview: View {
    let draft: TextDraft
    let latest: Item
    let keepChanges: () -> Bool
    let useLatest: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review the latest version").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Someone else saved this purchase first. Choose which details to continue editing.")
                .foregroundStyle(Palette.secondary)
            ConnectedConflictValues(title: "Your draft", fields: draft.fields)
            ConnectedConflictValues(title: "Latest shared version", fields: latest.fields)
                .accessibilityIdentifier("latestConflictVersion")
            Button("Keep my changes") { _ = keepChanges() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("keepConflictChanges")
            Button("Use latest version") { _ = useLatest() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("useLatestConflict")
        }
        .padding(16)
        .background(Palette.sage, in: .rect(cornerRadius: 16))
    }
}

private struct ConnectedConflictValues: View {
    let title: String
    let fields: ItemFields

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(fields.name)
            if let description = fields.description { Text(description) }
            if let brand = fields.brand { Text("Brand: \(brand)") }
            if let model = fields.model { Text("Model: \(model)") }
            if let date = fields.purchasedOn { Text("Purchased: \(date.rawValue)") }
            Text("On hand: \(fields.quantity)")
            Text("Restock limit: \(fields.restockLimit)")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private enum PurchaseDateEditor {
    static func date(from purchaseDate: PurchaseDate?) -> Date {
        guard let purchaseDate else { return .now }
        let pieces = purchaseDate.rawValue.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return .now }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) ?? .now
    }

    static func purchaseDate(from date: Date) -> PurchaseDate? {
        let pieces = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = pieces.year, let month = pieces.month, let day = pieces.day else { return nil }
        return try? PurchaseDate(String(format: "%04d-%02d-%02d", year, month, day))
    }
}

extension View {
    fileprivate func connectedFieldSurface() -> some View {
        font(.body)
            .padding(16)
            .background(Palette.surface)
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.border, lineWidth: 1) }
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 14))
    }
}
