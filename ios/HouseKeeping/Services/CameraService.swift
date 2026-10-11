@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CameraEvent: Equatable, Sendable {
    case interrupted
    case resumed
    case failed
}

enum CameraFailure: Error, Equatable, Sendable {
    case denied
    case unavailable
    case configuration
    case capture
    case interrupted
}

struct CameraPreviewSource: @unchecked Sendable {
    let session: AVCaptureSession
    let device: AVCaptureDevice
}

protocol CameraCapturing: Sendable {
    var events: AsyncStream<CameraEvent> { get }

    func start() async throws -> CameraPreviewSource?
    func stop() async
    func capture() async throws -> Data
}

/// Own once per presented camera. All session mutations run on one serial queue.
final class CameraService: CameraCapturing, @unchecked Sendable {
    let events: AsyncStream<CameraEvent>

    private let eventContinuation: AsyncStream<CameraEvent>.Continuation
    private let queue = DispatchQueue(label: "com.housekeeping.camera.session", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var observers: [NSObjectProtocol] = []
    private var captureDelegate: PhotoCaptureDelegate?
    private var isConfigured = false
    private var pendingStart: UUID?

    init() {
        let stream = AsyncStream.makeStream(of: CameraEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        eventContinuation.finish()
    }

    func start() async throws -> CameraPreviewSource? {
        let request = UUID()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                pendingStart = request
                continuation.resume()
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                await abandonStart(request)
                throw CameraFailure.denied
            }
        case .denied, .restricted:
            await abandonStart(request)
            throw CameraFailure.denied
        @unknown default:
            await abandonStart(request)
            throw CameraFailure.unavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard pendingStart == request else { throw CameraFailure.interrupted }
                    pendingStart = nil
                    if !isConfigured { try configure() }
                    guard let device else { throw CameraFailure.unavailable }
                    installObserversIfNeeded()
                    if !session.isRunning { session.startRunning() }
                    guard session.isRunning else { throw CameraFailure.unavailable }
                    continuation.resume(returning: CameraPreviewSource(session: session, device: device))
                } catch let failure as CameraFailure {
                    continuation.resume(throwing: failure)
                } catch {
                    continuation.resume(throwing: CameraFailure.configuration)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                pendingStart = nil
                let pendingCapture = captureDelegate
                captureDelegate = nil
                pendingCapture?.cancel()
                if session.isRunning { session.stopRunning() }
                removeObservers()
                continuation.resume()
            }
        }
    }

    private func abandonStart(_ request: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if pendingStart == request { pendingStart = nil }
                continuation.resume()
            }
        }
    }

    func capture() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning, !session.isInterrupted else {
                    continuation.resume(throwing: CameraFailure.interrupted)
                    return
                }
                guard captureDelegate == nil else {
                    continuation.resume(throwing: CameraFailure.capture)
                    return
                }

                let settings: AVCapturePhotoSettings
                if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.photoQualityPrioritization = .balanced
                if let connection = photoOutput.connection(with: .video),
                    let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
                    connection.isVideoRotationAngleSupported(angle)
                {
                    connection.videoRotationAngle = angle
                }

                let delegate = PhotoCaptureDelegate { [self] result in
                    queue.async { [self] in
                        captureDelegate = nil
                        continuation.resume(with: result)
                    }
                }
                captureDelegate = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func configure() throws {
        guard let selectedDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraFailure.unavailable }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: selectedDevice) } catch {
            throw CameraFailure.configuration
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CameraFailure.configuration
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        device = selectedDevice
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: selectedDevice, previewLayer: nil)
        isConfigured = true
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) {
                [eventContinuation] _ in eventContinuation.yield(.interrupted)
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) {
                [eventContinuation] _ in eventContinuation.yield(.resumed)
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
                [eventContinuation] _ in eventContinuation.yield(.failed)
            },
        ]
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let completion: @Sendable (Result<Data, CameraFailure>) -> Void
    private var result: Result<Data, CameraFailure>?
    private var isFinished = false

    init(completion: @escaping @Sendable (Result<Data, CameraFailure>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        lock.withLock {
            guard !isFinished else { return }
            if error != nil {
                result = .failure(.capture)
            } else if let data = photo.fileDataRepresentation(), !data.isEmpty,
                data.count <= PhotoPreparation.maximumSourceBytes
            {
                result = .success(data)
            } else {
                result = .failure(.capture)
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        finish(error == nil ? nil : .failure(.capture))
    }

    func cancel() {
        finish(.failure(.interrupted))
    }

    private func finish(_ override: Result<Data, CameraFailure>?) {
        let resolved: Result<Data, CameraFailure>? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            return override ?? result ?? .failure(.capture)
        }
        if let resolved { completion(resolved) }
    }
}

#if DEBUG
    actor PreviewCameraService: CameraCapturing {
        enum Mode: Sendable { case authorized, denied, unavailable }

        nonisolated let events: AsyncStream<CameraEvent>
        private let mode: Mode
        private var isRunning = false

        init(mode: Mode) {
            self.mode = mode
            events = AsyncStream { _ in }
        }

        func start() throws -> CameraPreviewSource? {
            switch mode {
            case .authorized:
                isRunning = true
                return nil
            case .denied:
                throw CameraFailure.denied
            case .unavailable:
                throw CameraFailure.unavailable
            }
        }

        func stop() { isRunning = false }

        func capture() throws -> Data {
            guard isRunning else { throw CameraFailure.interrupted }
            return try Self.syntheticJPEG()
        }

        private static func syntheticJPEG() throws -> Data {
            guard
                let context = CGContext(
                    data: nil, width: 720, height: 960, bitsPerComponent: 8, bytesPerRow: 720 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let destinationData = CFDataCreateMutable(nil, 0),
                let destination = CGImageDestinationCreateWithData(
                    destinationData, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw CameraFailure.capture }
            context.setFillColor(CGColor(red: 0.22, green: 0.42, blue: 0.31, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 960))
            context.setFillColor(CGColor(red: 0.93, green: 0.84, blue: 0.55, alpha: 1))
            context.fill(CGRect(x: 120, y: 190, width: 480, height: 580))
            guard let image = context.makeImage() else { throw CameraFailure.capture }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CameraFailure.capture }
            return destinationData as Data
        }
    }
#endif
