import CoreGraphics
import Foundation
import ImageIO
import Observation

/// One displayed image, owned by the current inventory session. No disk or global cache.
@MainActor @Observable
final class PrivatePhotoModel {
    enum Size: Int, Sendable {
        case thumbnail = 192
        case detail = 1_024
    }
    private(set) var image: CGImage?
    private(set) var failure: PhotoFailure?
    private(set) var isLoading = false
    @ObservationIgnored private var generation = UUID()

    func load(photoID: UUID, service: any PhotoService, size: Size = .detail) async {
        clear()
        let current = generation
        isLoading = true
        defer { if generation == current { isLoading = false } }
        do {
            let bytes = try await service.download(photoID: photoID)
            guard generation == current, !Task.isCancelled else { return }
            let decoded = try await PhotoDisplayDecoder().decode(bytes, size: size)
            guard generation == current, !Task.isCancelled else { return }
            image = decoded.image
        } catch {
            guard generation == current, !(error is CancellationError), !Task.isCancelled else { return }
            failure = error as? PhotoFailure ?? .unavailable
        }
    }

    func clear() {
        generation = UUID()
        image = nil
        failure = nil
        isLoading = false
    }
}

/// CGImage is immutable; only the finished decode crosses the actor boundary.
private struct DecodedPhoto: @unchecked Sendable {
    let image: CGImage
}

private actor PhotoDisplayDecoder {
    func decode(_ data: Data, size: PrivatePhotoModel.Size) throws -> DecodedPhoto {
        guard data.count <= PhotoPreparation.maximumOutputBytes,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...PhotoPreparation.maximumLongEdge).contains(width),
            (1...PhotoPreparation.maximumLongEdge).contains(height),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: size.rawValue,
                ] as CFDictionary)
        else { throw PhotoFailure.invalidResponse }
        return DecodedPhoto(image: image)
    }
}
