import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoPreparationFailure: Error, Equatable, Sendable {
    case invalidSource
    case sourceTooLarge
    case outputTooLarge
    case conversionFailed
}

struct PreparedPhoto: Equatable, Sendable {
    let jpegData: Data
    let width: Int
    let height: Int
}

struct ImageDraft: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let owner: DraftOwner
    let jpegData: Data
    let width: Int
    let height: Int
    var upload: PhotoUploadState?

    init(id: UUID = UUID(), owner: DraftOwner, prepared: PreparedPhoto) {
        self.id = id
        self.owner = owner
        jpegData = prepared.jpegData
        width = prepared.width
        height = prepared.height
    }

    func validateStorage() throws {
        try upload?.validate(owner: owner)
        let dimensions = try PreparedJPEG.inspect(jpegData)
        guard dimensions.width == width, dimensions.height == height else {
            throw DraftStorageFailure.invalidData
        }
    }
}

protocol ImageDraftStorage: Sendable {
    var owner: DraftOwner { get }
    func loadImageDraft() async throws -> ImageDraft?
    func saveImageDraft(_ draft: ImageDraft) async throws
    func clearImageDraft() async throws
}

protocol PhotoPreparing: Sendable {
    func prepare(_ sourceData: Data) async throws -> PreparedPhoto
}

actor PhotoPreparation: PhotoPreparing {
    static let maximumSourceBytes = 25 * 1_024 * 1_024
    static let maximumSourcePixels = 200_000_000
    static let maximumLongEdge = 2_048
    static let maximumOutputBytes = 5 * 1_024 * 1_024

    struct Limits: Sendable {
        let maximumSourceBytes: Int
        let maximumSourcePixels: Int
        let maximumLongEdge: Int
        let maximumOutputBytes: Int

        static let production = Limits(
            maximumSourceBytes: PhotoPreparation.maximumSourceBytes,
            maximumSourcePixels: PhotoPreparation.maximumSourcePixels,
            maximumLongEdge: PhotoPreparation.maximumLongEdge,
            maximumOutputBytes: PhotoPreparation.maximumOutputBytes
        )
    }

    private let limits: Limits

    init(limits: Limits = .production) {
        self.limits = limits
    }

    func prepare(_ sourceData: Data) throws -> PreparedPhoto {
        guard !sourceData.isEmpty else { throw PhotoPreparationFailure.invalidSource }
        guard sourceData.count <= limits.maximumSourceBytes else {
            throw PhotoPreparationFailure.sourceTooLarge
        }
        guard
            limits.maximumSourceBytes > 0,
            limits.maximumSourcePixels > 0,
            limits.maximumLongEdge > 0,
            limits.maximumOutputBytes > 0,
            let source = CGImageSourceCreateWithData(
                sourceData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetCount(source) == 1,
            let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let sourceWidth = (sourceProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let sourceHeight = (sourceProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            sourceWidth > 0,
            sourceHeight > 0
        else { throw PhotoPreparationFailure.invalidSource }
        guard
            sourceHeight <= limits.maximumSourcePixels,
            sourceWidth <= limits.maximumSourcePixels / sourceHeight
        else {
            throw PhotoPreparationFailure.sourceTooLarge
        }
        if let orientation = (sourceProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue {
            guard (1...8).contains(orientation) else { throw PhotoPreparationFailure.invalidSource }
        }

        let thumbnailProperties: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maximumLongEdge,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailProperties as CFDictionary
            ),
            image.width > 0,
            image.height > 0,
            max(image.width, image.height) <= limits.maximumLongEdge
        else { throw PhotoPreparationFailure.conversionFailed }

        for quality in [0.86, 0.76, 0.66, 0.56, 0.46] {
            let output = try encode(image, quality: quality)
            guard output.count <= limits.maximumOutputBytes else { continue }
            do {
                let dimensions = try PreparedJPEG.inspect(
                    output,
                    maximumLongEdge: limits.maximumLongEdge,
                    maximumBytes: limits.maximumOutputBytes
                )
                guard dimensions.width == image.width, dimensions.height == image.height else {
                    throw PhotoPreparationFailure.conversionFailed
                }
            } catch let failure as PhotoPreparationFailure {
                throw failure
            } catch {
                throw PhotoPreparationFailure.conversionFailed
            }
            return PreparedPhoto(jpegData: output, width: image.width, height: image.height)
        }
        throw PhotoPreparationFailure.outputTooLarge
    }

    private func encode(_ image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else { throw PhotoPreparationFailure.conversionFailed }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoPreparationFailure.conversionFailed
        }
        return output as Data
    }
}

private enum PreparedJPEG {
    static func inspect(
        _ data: Data,
        maximumLongEdge: Int = PhotoPreparation.maximumLongEdge,
        maximumBytes: Int = PhotoPreparation.maximumOutputBytes
    ) throws -> (width: Int, height: Int) {
        guard
            data.count >= 4,
            data.count <= maximumBytes,
            data[data.startIndex] == 0xff,
            data[data.index(after: data.startIndex)] == 0xd8,
            data[data.index(data.endIndex, offsetBy: -2)] == 0xff,
            data[data.index(before: data.endIndex)] == 0xd9,
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetCount(source) == 1,
            let sourceType = CGImageSourceGetType(source),
            UTType(sourceType as String)?.conforms(to: .jpeg) == true,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            hasNoSourceMetadata(properties),
            ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1,
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0,
            height > 0,
            max(width, height) <= maximumLongEdge,
            CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ) != nil
        else { throw DraftStorageFailure.invalidData }
        return (width, height)
    }

    private static func hasNoSourceMetadata(_ properties: [CFString: Any]) -> Bool {
        guard
            properties[kCGImagePropertyGPSDictionary] == nil,
            properties[kCGImagePropertyIPTCDictionary] == nil
        else { return false }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        guard
            exif?[kCGImagePropertyExifUserComment] == nil,
            exif?[kCGImagePropertyExifDateTimeOriginal] == nil,
            exif?[kCGImagePropertyExifDateTimeDigitized] == nil,
            exif?[kCGImagePropertyExifCameraOwnerName] == nil
        else { return false }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return tiff?[kCGImagePropertyTIFFArtist] == nil
            && tiff?[kCGImagePropertyTIFFDateTime] == nil
            && tiff?[kCGImagePropertyTIFFMake] == nil
            && tiff?[kCGImagePropertyTIFFModel] == nil
            && tiff?[kCGImagePropertyTIFFSoftware] == nil
    }
}
