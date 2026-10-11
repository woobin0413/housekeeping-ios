import CoreGraphics
import ImageIO
import Observation
import PhotosUI
import SwiftUI

struct PhotoImportView: View {
    let model: PhotoImportModel
    @State private var selectedItem: PhotosPickerItem?
    @State private var confirmsDiscard = false
    @State private var showsCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let draft = model.draft {
                ImageDraftPreview(draft: draft)
                Text("Ready on this iPhone · \(draft.width) × \(draft.height)")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                VStack(alignment: .leading) {
                    cameraButton
                    picker
                    Button("Discard photo", role: .destructive) { confirmsDiscard = true }
                        .frame(minHeight: 44)
                        .disabled(model.isBusy)
                }
            } else {
                ContentUnavailableView {
                    Label("Add a purchase photo", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Take a photo or choose an image to keep a private, prepared copy with this local draft.")
                } actions: {
                    cameraButton
                    picker
                }
            }
            if model.isTransferring || model.isPreparing {
                ProgressView(model.isTransferring ? "Reading your selection…" : "Preparing your photo…")
            }
            if let failure = model.failure {
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("photoImportError")
                if failure == .storage, !model.hasRestored {
                    Button("Retry local photo recovery") { Task { await model.restore() } }
                        .frame(minHeight: 44)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("retryPhotoDraftRecovery")
                }
            }
            Text(
                "Captures stay in HouseKeeping unless you save the purchase. Library originals stay unchanged. Location and source metadata aren’t copied."
            )
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
        }
        .task { await model.restore() }
        .task(id: selectedItem) {
            let item = selectedItem
            guard let item, model.beginTransfer() else { return }
            defer {
                model.endTransfer()
                selectedItem = nil
            }
            do {
                guard let selection = try await item.loadTransferable(type: BoundedPhotoSelection.self) else {
                    model.recordTransferFailure()
                    return
                }
                try Task.checkCancellation()
                model.endTransfer()
                await model.importData(selection.data)
            } catch is CancellationError {
                return
            } catch {
                model.recordTransferFailure(error)
            }
        }
        .alert("Discard this photo?", isPresented: $confirmsDiscard) {
            Button("Discard photo", role: .destructive) {
                Task { _ = await model.discard(confirmed: true) }
            }
            Button("Keep photo", role: .cancel) {}
        } message: {
            Text("The prepared local copy will be removed. The original library photo will not change.")
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraCaptureView(photoDraft: model)
        }
    }

    private var cameraButton: some View {
        Button {
            showsCamera = true
        } label: {
            Label(model.draft == nil ? "Take a photo" : "Take another photo", systemImage: "camera")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.hasRestored || model.isBusy)
        .accessibilityIdentifier("takePurchasePhoto")
    }

    private var picker: some View {
        let title = model.draft == nil ? "Choose from library" : "Choose another photo"
        return PhotosPicker(
            selection: $selectedItem,
            matching: .images,
            preferredItemEncoding: .current
        ) {
            Label(title, systemImage: "photo")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.hasRestored || model.isBusy)
        .accessibilityIdentifier("choosePurchasePhoto")
    }
}

@MainActor @Observable
final class PhotoImportModel {
    private(set) var draft: ImageDraft?
    private(set) var hasRestored = false
    private(set) var isRestoring = false
    private(set) var isPreparing = false
    private(set) var isTransferring = false
    private(set) var failure: PhotoImportFailure?
    private(set) var isActive = true
    private(set) var isClosing = false
    private(set) var uploadStage: PhotoUploadStage?
    private(set) var uploadFailure: PhotoFailure?
    @ObservationIgnored private let storage: any ImageDraftStorage
    @ObservationIgnored private let preparation: any PhotoPreparing
    @ObservationIgnored private let service: (any PhotoService)?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var pendingWork: Task<Void, Never>?
    @ObservationIgnored private var workGeneration = UUID()

    var isBusy: Bool { isRestoring || isPreparing || isTransferring || isClosing || uploadStage != nil || !isActive }
    var needsDiscardConfirmation: Bool {
        !hasRestored || draft != nil || failure == .storage || isPreparing || isTransferring
    }
    var blocksPurchaseSave: Bool { !hasRestored || draft != nil || isBusy || failure == .storage }

    /// Used only after a definite create rejection, never after an uncertain network result.
    func resetRejectedUpload() async -> Bool {
        guard !isBusy, var current = draft else { return false }
        isPreparing = true
        let work = UUID()
        workGeneration = work
        current.upload = nil
        let task = Task {
            defer { isPreparing = false }
            do {
                try await persistUpload(current)
                uploadFailure = nil
            } catch {
                uploadFailure = .protectedStorage
            }
        }
        pendingWork = task
        await task.value
        if workGeneration == work { pendingWork = nil }
        return workGeneration == work && isActive && !isBusy && uploadFailure == nil
    }

    /// The text draft's acknowledged cleanup already removed both protected files.
    func purchaseSaved() {
        guard !isBusy else { return }
        draft = nil
        uploadFailure = nil
        failure = nil
    }

    init(storage: any ImageDraftStorage, preparation: any PhotoPreparing, service: (any PhotoService)? = nil) {
        self.storage = storage
        self.preparation = preparation
        self.service = service
    }

    func beginTransfer() -> Bool {
        guard hasRestored, !isBusy else { return false }
        isTransferring = true
        return true
    }

    func endTransfer() { isTransferring = false }

    func restore() async {
        guard isActive, !isClosing, !hasRestored, !isRestoring else { return }
        let current = UUID()
        operation = current
        isRestoring = true
        defer { if operation == current { isRestoring = false } }
        do {
            let restored = try await storage.loadImageDraft()
            guard operation == current else { return }
            guard restored == nil || restored?.owner == storage.owner else {
                throw DraftStorageFailure.invalidData
            }
            draft = restored
            hasRestored = true
            failure = nil
        } catch {
            guard operation == current else { return }
            failure = .storage
        }
    }

    func importData(_ sourceData: Data) async {
        guard hasRestored, !isBusy else { return }
        isPreparing = true
        uploadFailure = nil
        let work = UUID()
        workGeneration = work
        let task = Task { await prepareAndSave(sourceData) }
        pendingWork = task
        await task.value
        if workGeneration == work { pendingWork = nil }
    }

    /// Persists reservation identity before network writes. A lost upload response is recovered by completion.
    func uploadForSave() async -> UUID? {
        guard hasRestored, !isBusy, let draft, let service else { return nil }
        guard service.owner == storage.owner else {
            uploadFailure = .validation
            return nil
        }
        let imageID = draft.id
        let work = UUID()
        workGeneration = work
        uploadStage = .reserving
        uploadFailure = nil
        let task = Task { await uploadCurrentDraft(using: service) }
        pendingWork = task
        await task.value
        if workGeneration == work { pendingWork = nil }
        guard workGeneration == work, isActive, !isBusy, self.draft?.id == imageID,
            uploadFailure == nil, self.draft?.upload?.isReady == true
        else { return nil }
        return self.draft?.upload?.reservation?.photoId
    }

    /// Persists the provider request identity before any recognition call. A definite retry state
    /// may renew it; uncertain transport failures keep the prior identity for safe server replay.
    func recognitionRequest(renewing: Bool) async -> RecognitionRequestIdentity? {
        guard let photoID = await uploadForSave(), !isBusy, var current = draft,
            current.upload?.isReady == true, current.upload?.reservation?.photoId == photoID
        else { return nil }
        if current.upload?.recognitionRequestId == nil
            || current.upload?.recognitionRetryRequired == true || renewing
        {
            isPreparing = true
            defer { isPreparing = false }
            current.upload?.recognitionRequestId = UUID()
            current.upload?.recognitionRetryRequired = nil
            do {
                try await persistUpload(current)
                uploadFailure = nil
            } catch {
                uploadFailure = .protectedStorage
                return nil
            }
        }
        guard let requestID = draft?.upload?.recognitionRequestId else { return nil }
        return RecognitionRequestIdentity(photoId: photoID, requestId: requestID)
    }

    @discardableResult
    func markRecognitionRetryRequired() async -> Bool {
        guard !isBusy, var current = draft, current.upload?.recognitionRequestId != nil else { return false }
        current.upload?.recognitionRetryRequired = true
        do {
            try await persistUpload(current)
            return true
        } catch {
            uploadFailure = .protectedStorage
            return false
        }
    }

    private func uploadCurrentDraft(using service: any PhotoService) async {
        guard var current = draft else {
            uploadStage = nil
            return
        }
        defer { uploadStage = nil }
        do {
            if let expiresAt = current.upload?.reservation?.expiresAt, expiresAt <= Date() {
                current.upload = nil
            }
            if current.upload == nil {
                current.upload = PhotoUploadState(requestId: UUID())
                try await persistUpload(current)
            }
            guard let requestID = current.upload?.requestId else { throw PhotoFailure.invalidResponse }
            if current.upload?.reservation == nil {
                uploadStage = .reserving
                current.upload?.reservation = try await service.reserve(requestID: requestID)
                try await persistUpload(current)
            }
            guard let reservation = current.upload?.reservation else { throw PhotoFailure.invalidResponse }
            guard reservation.expiresAt > Date() else { throw PhotoFailure.expired }
            if current.upload?.isReady != true {
                uploadStage = .validating
                do {
                    try await service.complete(reservation)
                } catch PhotoFailure.uploadIncomplete {
                    uploadStage = .uploading
                    try await service.upload(current, to: reservation)
                    uploadStage = .validating
                    try await service.complete(reservation)
                }
                current.upload?.isReady = true
                try await persistUpload(current)
            }
        } catch let error as PhotoFailure {
            uploadFailure = error
            if error == .expired {
                // The reservation reply may have been lost, leaving no local expiry to inspect.
                // A definite server expiry permits a fresh request on the next explicit retry.
                current.upload = nil
                do { try await persistUpload(current) } catch { uploadFailure = .protectedStorage }
            }
        } catch is DraftStorageFailure {
            uploadFailure = .protectedStorage
        } catch is CancellationError {
            uploadFailure = .unavailable
        } catch {
            uploadFailure = .unavailable
        }
    }

    private func persistUpload(_ draft: ImageDraft) async throws {
        try await storage.saveImageDraft(draft)
        self.draft = draft
    }

    private func prepareAndSave(_ sourceData: Data) async {
        let current = UUID()
        operation = current
        isPreparing = true
        failure = nil
        defer { if operation == current { isPreparing = false } }
        do {
            let prepared = try await preparation.prepare(sourceData)
            guard operation == current, !Task.isCancelled else { return }
            let candidate = ImageDraft(owner: storage.owner, prepared: prepared)
            try await storage.saveImageDraft(candidate)
            guard operation == current, !Task.isCancelled else { return }
            draft = candidate
        } catch let error as PhotoPreparationFailure {
            guard operation == current else { return }
            failure = PhotoImportFailure(error)
        } catch {
            guard operation == current else { return }
            failure = .storage
        }
    }

    func recordTransferFailure(_ error: (any Error)? = nil) {
        guard isActive, !isClosing else { return }
        failure = (error as? PhotoPreparationFailure).map(PhotoImportFailure.init) ?? .transfer
    }

    @discardableResult
    func discard(confirmed: Bool) async -> Bool {
        guard confirmed, !isBusy else { return false }
        let current = UUID()
        operation = current
        isPreparing = true
        defer { if operation == current { isPreparing = false } }
        do {
            try await storage.clearImageDraft()
            guard operation == current else { return false }
            draft = nil
            failure = nil
            uploadFailure = nil
            hasRestored = true
            return true
        } catch {
            guard operation == current else { return false }
            failure = .storage
            return false
        }
    }

    /// Drain any protected-file write before clearing or releasing this session.
    func close(discard: Bool) async -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        defer { isClosing = false }
        await pendingWork?.value
        operation = UUID()
        isPreparing = false
        isRestoring = false
        isTransferring = false
        uploadStage = nil
        if discard {
            do { try await storage.clearImageDraft() } catch {
                failure = .storage
                return false
            }
        }
        isActive = false
        draft = nil
        return true
    }
}

/// File transfer keeps the input allocation bounded before ImageIO sees any bytes.
private struct BoundedPhotoSelection: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let file = try FileHandle(forReadingFrom: received.file)
            defer { try? file.close() }
            let data = try file.read(upToCount: PhotoPreparation.maximumSourceBytes + 1) ?? Data()
            guard data.count <= PhotoPreparation.maximumSourceBytes else {
                throw PhotoPreparationFailure.sourceTooLarge
            }
            return Self(data: data)
        }
    }
}

enum PhotoImportFailure: Equatable {
    case invalidImage
    case sourceTooLarge
    case outputTooLarge
    case conversion
    case transfer
    case storage

    init(_ failure: PhotoPreparationFailure) {
        switch failure {
        case .invalidSource: self = .invalidImage
        case .sourceTooLarge: self = .sourceTooLarge
        case .outputTooLarge: self = .outputTooLarge
        case .conversionFailed: self = .conversion
        }
    }

    var message: String {
        switch self {
        case .invalidImage: "That file isn’t a supported single image. Choose another photo."
        case .sourceTooLarge: "That source image is too large to prepare safely. Choose a smaller photo."
        case .outputTooLarge: "The prepared photo is still over 5 MiB. Choose a simpler or smaller image."
        case .conversion: "This photo couldn’t be converted. Choose another image and try again."
        case .transfer: "The photo couldn’t be read from your library. Check access and try again."
        case .storage: "The protected local photo draft couldn’t be updated. Unlock this iPhone and retry."
        }
    }
}

extension PhotoUploadStage {
    var message: String {
        switch self {
        case .reserving: "Preparing private upload…"
        case .uploading: "Uploading photo…"
        case .validating: "Checking uploaded photo…"
        }
    }
}

extension PhotoFailure {
    var message: String {
        switch self {
        case .unauthenticated: "Your session ended. Check your account to continue."
        case .forbidden: "Your household access needs to be checked before continuing."
        case .notFound: "This photo is no longer available. Refresh the purchase to check its latest details."
        case .expired: "The upload expired. Your draft is safe; retry to upload a fresh copy."
        case .protectedStorage: "Unlock this iPhone and retry. Your prepared photo has not been discarded."
        case .validation, .invalidResponse: "This photo couldn’t be verified. Retry or choose another image."
        case .uploadIncomplete, .conflict, .unavailable:
            "The photo couldn’t be loaded or uploaded. Check your connection and retry. Your draft is safe."
        }
    }
}

private struct ImageDraftPreview: View {
    let draft: ImageDraft
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Palette.sage)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView("Opening photo…")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 320)
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected purchase photo")
        .task(id: draft.id) {
            let data = draft.jpegData
            let decoded: SendableImage? = await Task.detached(priority: .userInitiated) {
                () -> SendableImage? in
                guard
                    let source = CGImageSourceCreateWithData(
                        data as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary
                    ),
                    let image = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1_024,
                        ] as CFDictionary
                    )
                else { return nil }
                return SendableImage(image)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded?.image
        }
    }
}

private struct SendableImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
