@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing

@testable import HouseKeeping

@MainActor
struct CameraFlowTests {
    @Test func permissionIsRequestedOnlyAfterCameraStarts() async {
        let service = ControlledCameraService()
        let model = CameraCaptureModel(service: service)

        #expect(await service.startCount == 0)
        #expect(model.phase == .idle)
        await model.start()
        #expect(await service.startCount == 1)
        #expect(model.phase == .ready)
        await model.stop()
        #expect(await service.stopCount == 1)
    }

    @Test func deniedPermissionLeavesAStableFallbackState() async {
        let service = ControlledCameraService(startFailure: .denied)
        let model = CameraCaptureModel(service: service)

        await model.start()

        #expect(model.phase == .denied)
        #expect(model.capturedData == nil)
        #expect(!model.canCapture)
        #expect(await service.captureCount == 0)
    }

    @Test func captureRetakeAndUsePersistAnOrientedMetadataFreeDraft() async throws {
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let storage = CameraDraftStorage(owner: owner)
        let photoDraft = PhotoImportModel(storage: storage, preparation: PhotoPreparation())
        await photoDraft.restore()
        let source = try photoFixtureJPEG(width: 80, height: 40, orientation: 6, metadata: true)
        let service = ControlledCameraService(captureData: source)
        let model = CameraCaptureModel(service: service)

        await model.start()
        await model.capture()
        #expect(model.phase == .captured)
        #expect(model.capturedData == source)
        #expect(await storage.loadImageDraft() == nil)

        model.retake()
        #expect(model.phase == .ready)
        #expect(model.capturedData == nil)
        await model.capture()
        #expect(await model.useCapture(in: photoDraft))

        let saved = try #require(await storage.loadImageDraft())
        #expect(saved.width == 40)
        #expect(saved.height == 80)
        #expect(saved.jpegData.count <= PhotoPreparation.maximumOutputBytes)
        let imageSource = try #require(CGImageSourceCreateWithData(saved.jpegData as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(exif?[kCGImagePropertyExifCameraOwnerName] == nil)
        #expect(await service.captureCount == 2)
    }

    @Test func interruptionDisablesCaptureUntilTheSessionResumes() async {
        let service = ControlledCameraService()
        let model = CameraCaptureModel(service: service)
        await model.start()

        await service.send(.interrupted)
        for _ in 0..<100 where !model.isInterrupted { await Task.yield() }
        #expect(model.isInterrupted)
        #expect(!model.canCapture)
        await model.capture()
        #expect(await service.captureCount == 0)

        await service.send(.resumed)
        for _ in 0..<100 where model.isInterrupted { await Task.yield() }
        #expect(!model.isInterrupted)
        #expect(model.canCapture)
    }
}

private actor ControlledCameraService: CameraCapturing {
    nonisolated let events: AsyncStream<CameraEvent>
    private nonisolated let eventContinuation: AsyncStream<CameraEvent>.Continuation
    private let startFailure: CameraFailure?
    private let captureData: Data
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var captureCount = 0

    init(startFailure: CameraFailure? = nil, captureData: Data = Data([0x01])) {
        self.startFailure = startFailure
        self.captureData = captureData
        let stream = AsyncStream.makeStream(of: CameraEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func start() throws -> CameraPreviewSource? {
        startCount += 1
        if let startFailure { throw startFailure }
        return nil
    }

    func stop() { stopCount += 1 }

    func capture() throws -> Data {
        captureCount += 1
        return captureData
    }

    func send(_ event: CameraEvent) { eventContinuation.yield(event) }
}

private actor CameraDraftStorage: ImageDraftStorage {
    nonisolated let owner: DraftOwner
    private var draft: ImageDraft?

    init(owner: DraftOwner) { self.owner = owner }

    func loadImageDraft() -> ImageDraft? { draft }

    func saveImageDraft(_ draft: ImageDraft) throws {
        try draft.validateStorage()
        self.draft = draft
    }

    func clearImageDraft() { draft = nil }
}
