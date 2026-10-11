import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import HouseKeeping

struct PhotoPreparationTests {
    @Test(arguments: [UTType.png, UTType.heic])
    func convertsLibraryFormatsToJPEG(_ type: UTType) async throws {
        let input = try photoFixtureJPEG(width: 64, height: 32, type: type)
        let result = try await PhotoPreparation().prepare(input)
        let source = try #require(CGImageSourceCreateWithData(result.jpegData as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(result.width == 64 && result.height == 32)
    }

    @Test func appliesOrientationAndRemovesSourceMetadataWithoutMutatingInput() async throws {
        let source = try photoFixtureJPEG(width: 40, height: 20, orientation: 6, metadata: true)
        let unchanged = source
        let originalProperties = try imageProperties(source)
        #expect(originalProperties[kCGImagePropertyGPSDictionary] != nil)

        let result = try await PhotoPreparation().prepare(source)

        #expect(source == unchanged)
        #expect(result.width == 20)
        #expect(result.height == 40)
        #expect(result.jpegData.count <= PhotoPreparation.maximumOutputBytes)
        let properties = try imageProperties(result.jpegData)
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFArtist] == nil)
    }

    @Test(arguments: 1...8)
    func normalizesEveryEXIFOrientation(_ orientation: Int) async throws {
        let result = try await PhotoPreparation().prepare(
            photoFixtureJPEG(width: 80, height: 40, orientation: orientation))
        #expect(result.width == (orientation >= 5 ? 40 : 80))
        #expect(result.height == (orientation >= 5 ? 80 : 40))
        // The fixture's red patch starts at the lower left in drawing coordinates.
        // Read back its corner after transformation to detect missed mirroring/rotation.
        let expectedRedCorners = [2, 3, 1, 0, 1, 0, 2, 3]
        let source = try #require(CGImageSourceCreateWithData(result.jpegData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let points = [
            (4, 4), (image.width - 5, 4), (4, image.height - 5),
            (image.width - 5, image.height - 5),
        ]
        let redCorners = points.enumerated().compactMap { index, point -> Int? in
            let offset = (point.1 * image.width + point.0) * 4
            return pixels[offset] > pixels[offset + 2] ? index : nil
        }
        #expect(redCorners == [expectedRedCorners[orientation - 1]])
    }

    @Test func downscalesLongEdgeAndHonorsProductionUploadCap() async throws {
        let source = try photoFixtureJPEG(width: 3_000, height: 1_500)
        let result = try await PhotoPreparation().prepare(source)

        #expect(result.width == PhotoPreparation.maximumLongEdge)
        #expect(result.height == PhotoPreparation.maximumLongEdge / 2)
        #expect(result.jpegData.count <= 5 * 1_024 * 1_024)
        let properties = try imageProperties(result.jpegData)
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == result.width)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == result.height)
    }

    @Test func rejectsInvalidSourcesAndBoundedConversionFailures() async throws {
        let valid = try photoFixtureJPEG(width: 32, height: 24)
        await #expect(throws: PhotoPreparationFailure.invalidSource) {
            try await PhotoPreparation().prepare(Data("not an image".utf8))
        }
        await #expect(throws: PhotoPreparationFailure.sourceTooLarge) {
            try await PhotoPreparation(
                limits: .init(
                    maximumSourceBytes: valid.count - 1,
                    maximumSourcePixels: PhotoPreparation.maximumSourcePixels,
                    maximumLongEdge: PhotoPreparation.maximumLongEdge,
                    maximumOutputBytes: PhotoPreparation.maximumOutputBytes
                )
            ).prepare(valid)
        }
        await #expect(throws: PhotoPreparationFailure.outputTooLarge) {
            try await PhotoPreparation(
                limits: .init(
                    maximumSourceBytes: PhotoPreparation.maximumSourceBytes,
                    maximumSourcePixels: PhotoPreparation.maximumSourcePixels,
                    maximumLongEdge: PhotoPreparation.maximumLongEdge,
                    maximumOutputBytes: 64
                )
            ).prepare(valid)
        }
        await #expect(throws: PhotoPreparationFailure.sourceTooLarge) {
            try await PhotoPreparation(
                limits: .init(
                    maximumSourceBytes: valid.count, maximumSourcePixels: 767,
                    maximumLongEdge: 2048, maximumOutputBytes: 5 * 1024 * 1024)
            ).prepare(valid)
        }
    }

    @MainActor @Test
    func importFailureKeepsRecoverableDraftUntilExplicitDiscard() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "housekeeping-photo-model-test-\(UUID())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let storage = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!,
            owner: owner,
            rootDirectory: root
        )
        let model = PhotoImportModel(storage: storage, preparation: PhotoPreparation())
        await model.restore()
        await model.importData(try photoFixtureJPEG(width: 32, height: 24))
        let saved = try #require(model.draft)

        await model.importData(Data("not an image".utf8))
        #expect(model.draft == saved)
        #expect(model.failure == .invalidImage)
        await model.discard(confirmed: false)
        #expect(model.draft == saved)
        await model.discard(confirmed: true)
        #expect(model.draft == nil)
        #expect(try await storage.loadImageDraft() == nil)
    }

    @MainActor @Test
    func closingSessionDrainsImportThenClearsDiskAndRejectsLateWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "housekeeping-photo-close-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!,
            owner: .init(accountID: UUID(), householdID: UUID()), rootDirectory: root)
        let preparation = HeldPhotoPreparation()
        let model = PhotoImportModel(storage: storage, preparation: preparation)
        await model.restore()
        let data = try photoFixtureJPEG(width: 32, height: 24)
        let prepared = try await PhotoPreparation().prepare(data)
        let importing = Task { await model.importData(data) }
        for _ in 0..<1000 {
            if await preparation.isWaiting { break }
            await Task.yield()
        }
        #expect(await preparation.isWaiting)
        let closing = Task { await model.close(discard: true) }
        for _ in 0..<1000 {
            if model.isClosing { break }
            await Task.yield()
        }
        #expect(model.isClosing)
        await preparation.finish(prepared)
        await importing.value
        #expect(await closing.value)
        #expect(model.draft == nil && !model.isActive)
        #expect(try await storage.loadImageDraft() == nil)
        await model.importData(data)
        #expect(try await storage.loadImageDraft() == nil)
    }

    @MainActor @Test
    func inventoryRetirementRecoversPhotoAndConfirmedSignOutClearsBothDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "housekeeping-photo-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!,
            owner: .init(accountID: UUID(), householdID: UUID()), rootDirectory: root)
        let database = PreviewInventoryDatabase()
        let repository = PreviewInventoryRepository(householdID: storage.owner.householdID, database: database)
        let store = InventoryStore(repository: repository, draftStorage: storage)
        await store.drafts.restore()
        let photo = try #require(store.photoDraft)
        await photo.restore()
        #expect(store.beginDraft())
        #expect(store.drafts.edit(.init(name: "Photo purchase")))
        await photo.importData(try photoFixtureJPEG(width: 32, height: 24))
        let savedPhoto = try #require(photo.draft)
        #expect(await store.saveDraft() == nil)
        #expect(database.items(householdID: storage.owner.householdID).count == 1)
        #expect(!(await store.deactivate(confirmedDiscard: false)))
        #expect(await store.retire())
        #expect(photo.draft == nil && !photo.isActive)

        let reopened = InventoryStore(repository: repository, draftStorage: storage)
        await reopened.drafts.restore()
        await reopened.photoDraft?.restore()
        #expect(reopened.photoDraft?.draft == savedPhoto)
        #expect(reopened.drafts.draft?.fields.name == "Photo purchase")
        #expect(await reopened.deactivate(confirmedDiscard: true))
        #expect(try await storage.load() == nil)
        #expect(try await storage.loadImageDraft() == nil)
        #expect(reopened.photoDraft?.draft == nil)
    }
}

private actor HeldPhotoPreparation: PhotoPreparing {
    private var continuation: CheckedContinuation<PreparedPhoto, Never>?
    var isWaiting: Bool { continuation != nil }
    func prepare(_ data: Data) async throws -> PreparedPhoto {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ photo: PreparedPhoto) {
        continuation?.resume(returning: photo)
        continuation = nil
    }
}

func photoFixtureJPEG(
    width: Int,
    height: Int,
    orientation: Int = 1,
    metadata: Bool = false,
    type: UTType = .jpeg
) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { throw PhotoFixtureFailure.creation }
    context.setFillColor(CGColor(red: 0.18, green: 0.42, blue: 0.73, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.91, green: 0.35, blue: 0.22, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: max(1, width / 3), height: max(1, height / 2)))
    guard let image = context.makeImage() else { throw PhotoFixtureFailure.creation }

    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        )
    else { throw PhotoFixtureFailure.creation }
    var properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyOrientation: orientation,
    ]
    if metadata {
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: 40.7128,
            kCGImagePropertyGPSLatitudeRef: "N",
        ]
        properties[kCGImagePropertyExifDictionary] = [
            kCGImagePropertyExifUserComment: "private fixture note"
        ]
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFArtist: "private fixture author"
        ]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw PhotoFixtureFailure.creation }
    return data as Data
}

private func imageProperties(_ data: Data) throws -> [CFString: Any] {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { throw PhotoFixtureFailure.creation }
    return properties
}

private enum PhotoFixtureFailure: Error { case creation }
