@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class CameraCaptureModel {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case ready
        case capturing
        case captured
        case denied
        case unavailable
    }

    private(set) var phase: Phase = .idle
    private(set) var previewSource: CameraPreviewSource?
    private(set) var capturedData: Data?
    private(set) var isInterrupted = false
    @ObservationIgnored private let service: any CameraCapturing
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(service: any CameraCapturing) {
        self.service = service
    }

    var canCapture: Bool { phase == .ready && !isInterrupted }

    func start() async {
        guard phase == .idle else { return }
        let current = UUID()
        generation = current
        phase = .requestingPermission
        isInterrupted = false
        eventsTask = Task { [weak self, events = service.events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event, generation: current)
            }
        }
        do {
            let source = try await service.start()
            guard generation == current, !Task.isCancelled else { return }
            previewSource = source
            phase = .ready
        } catch CameraFailure.denied {
            guard generation == current else { return }
            phase = .denied
        } catch {
            guard generation == current else { return }
            phase = .unavailable
        }
    }

    func capture() async {
        guard canCapture else { return }
        let current = generation
        phase = .capturing
        do {
            let data = try await service.capture()
            guard generation == current, !Task.isCancelled else { return }
            capturedData = data
            phase = .captured
        } catch CameraFailure.interrupted {
            guard generation == current else { return }
            isInterrupted = true
            phase = .ready
        } catch {
            guard generation == current else { return }
            phase = .unavailable
        }
    }

    func retake() {
        guard phase == .captured else { return }
        capturedData = nil
        phase = .ready
    }

    func useCapture(in photoDraft: PhotoImportModel) async -> Bool {
        guard phase == .captured, let capturedData, photoDraft.hasRestored, !photoDraft.isBusy else {
            return false
        }
        let previousID = photoDraft.draft?.id
        await photoDraft.importData(capturedData)
        return photoDraft.failure == nil && photoDraft.draft?.id != previousID
    }

    func stop() async {
        generation = UUID()
        eventsTask?.cancel()
        eventsTask = nil
        await service.stop()
        previewSource = nil
        capturedData = nil
        isInterrupted = false
        phase = .idle
    }

    private func receive(_ event: CameraEvent, generation expected: UUID) {
        guard generation == expected else { return }
        switch event {
        case .interrupted:
            isInterrupted = true
        case .resumed:
            isInterrupted = false
        case .failed:
            capturedData = nil
            previewSource = nil
            phase = .unavailable
        }
    }
}

struct CameraCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    let photoDraft: PhotoImportModel
    @State private var camera: CameraCaptureModel
    @State private var isUsingPhoto = false

    init(photoDraft: PhotoImportModel) {
        self.photoDraft = photoDraft
        _camera = State(initialValue: CameraCaptureModel(service: Self.makeCameraService()))
    }

    var body: some View {
        NavigationStack {
            CameraCaptureContent(camera: camera, photoDraft: photoDraft, isUsingPhoto: $isUsingPhoto)
                .navigationTitle("Take a photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.black, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(.white)
                            .disabled(camera.phase == .capturing || isUsingPhoto)
                    }
                }
        }
        .tint(Palette.action)
        .task { await camera.start() }
        .onDisappear { Task { await camera.stop() } }
        .accessibilityIdentifier("cameraCaptureView")
    }

    @MainActor
    private static func makeCameraService() -> any CameraCapturing {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--preview-camera-authorized") {
                return PreviewCameraService(mode: .authorized)
            }
            if arguments.contains("--preview-camera-denied") {
                return PreviewCameraService(mode: .denied)
            }
            if arguments.contains("--preview-camera-unavailable") {
                return PreviewCameraService(mode: .unavailable)
            }
        #endif
        return CameraService()
    }
}

private struct CameraCaptureContent: View {
    @Environment(\.dismiss) private var dismiss
    let camera: CameraCaptureModel
    let photoDraft: PhotoImportModel
    @Binding var isUsingPhoto: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.phase {
            case .idle, .requestingPermission:
                ProgressView("Opening camera…").tint(.white).foregroundStyle(.white)
            case .denied:
                CameraFallback(
                    title: "Camera access is off",
                    message: "Choose a photo from your library or continue entering purchase details manually.",
                    symbol: "camera.fill.badge.xmark")
            case .unavailable:
                CameraFallback(
                    title: "Camera unavailable",
                    message: "The camera couldn’t start. Return to choose from your library or enter details manually.",
                    symbol: "camera.fill")
            case .ready, .capturing:
                CameraLiveCapture(camera: camera)
            case .captured:
                if let data = camera.capturedData {
                    CameraCapturedPreview(data: data)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            controls
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(.black)
        }
        .overlay(alignment: .top) {
            if camera.isInterrupted {
                Text("Camera paused. It will be ready when the interruption ends.")
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Palette.sage)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("cameraInterrupted")
            } else if camera.phase == .captured, let failure = photoDraft.failure {
                Text(failure.message)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Palette.sage)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("cameraPhotoError")
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch camera.phase {
        case .ready, .capturing:
            Button {
                Task { await camera.capture() }
            } label: {
                if camera.phase == .capturing {
                    ProgressView("Taking photo…").tint(.black)
                } else {
                    Label("Take photo", systemImage: "camera.fill")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!camera.canCapture)
            .accessibilityIdentifier("capturePurchasePhoto")
        case .captured:
            HStack(spacing: 16) {
                Button("Retake") { camera.retake() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .frame(minHeight: 44)
                    .disabled(isUsingPhoto)
                    .accessibilityIdentifier("retakePurchasePhoto")
                Button {
                    Task {
                        isUsingPhoto = true
                        defer { isUsingPhoto = false }
                        if await camera.useCapture(in: photoDraft) { dismiss() }
                    }
                } label: {
                    if isUsingPhoto {
                        ProgressView("Preparing photo…").tint(Palette.actionText)
                    } else {
                        Label("Use photo", systemImage: "checkmark")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isUsingPhoto || photoDraft.isBusy)
                .accessibilityIdentifier("useCapturedPhoto")
            }
        case .denied, .unavailable:
            Button("Back to photo options") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("cameraFallback")
        case .idle, .requestingPermission:
            EmptyView()
        }
    }
}

private struct CameraLiveCapture: View {
    let camera: CameraCaptureModel

    var body: some View {
        if let source = camera.previewSource {
            CameraPreview(source: source)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(Color(red: 0.12, green: 0.20, blue: 0.15))
                .overlay {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.85))
                        .accessibilityHidden(true)
                }
        }
    }
}

private struct CameraFallback: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .foregroundStyle(.white)
        .padding(24)
    }
}

private struct CameraCapturedPreview: View {
    let data: Data
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.black)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView("Opening photo…").tint(.white).foregroundStyle(.white)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Captured purchase photo preview")
            .accessibilityIdentifier("capturedPhotoPreview")
            .task {
                let captured = data
                image = await Task.detached(priority: .userInitiated) { () -> SendableCameraImage? in
                    guard
                        let source = CGImageSourceCreateWithData(
                            captured as CFData,
                            [kCGImageSourceShouldCache: false] as CFDictionary),
                        let image = CGImageSourceCreateThumbnailAtIndex(
                            source, 0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceShouldCacheImmediately: true,
                                kCGImageSourceThumbnailMaxPixelSize: 1_024,
                            ] as CFDictionary)
                    else { return nil }
                    return SendableCameraImage(image: image)
                }.value?.image
            }
    }
}

private struct SendableCameraImage: @unchecked Sendable {
    let image: CGImage
}

private struct CameraPreview: UIViewRepresentable {
    let source: CameraPreviewSource

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.configure(source)
        return view
    }

    func updateUIView(_ view: CameraPreviewUIView, context: Context) {
        view.configure(source)
    }
}

private final class CameraPreviewUIView: UIView, @unchecked Sendable {
    private var sourceSession: AVCaptureSession?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func configure(_ source: CameraPreviewSource) {
        guard sourceSession !== source.session else { return }
        sourceSession = source.session
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = source.session
        let coordinator = AVCaptureDevice.RotationCoordinator(device: source.device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            // AVFoundation documents these KVO callbacks as main-queue delivery.
            MainActor.assumeIsolated {
                guard let connection = self?.previewLayer.connection,
                    connection.isVideoRotationAngleSupported(angle)
                else { return }
                connection.videoRotationAngle = angle
            }
        }
    }
}
