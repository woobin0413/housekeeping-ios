import Foundation

enum PhotoFailure: Error, Equatable, Sendable {
    case validation, unauthenticated, forbidden, notFound, expired, uploadIncomplete
    case conflict, protectedStorage, invalidResponse, unavailable
}

struct PhotoReservation: Codable, Equatable, Sendable {
    let photoId: UUID
    let objectKey: String
    let expiresAt: Date

    func validate(owner: DraftOwner) throws {
        guard objectKey == Self.objectKey(householdID: owner.householdID, uploaderID: owner.accountID, photoID: photoId)
        else { throw PhotoFailure.invalidResponse }
    }

    static func objectKey(householdID: UUID, uploaderID: UUID, photoID: UUID) -> String {
        "\(householdID)/\(uploaderID)/\(photoID).jpg".lowercased()
    }
}

/// Stored with the prepared bytes. A reservation retry must keep its original request ID.
struct PhotoUploadState: Codable, Equatable, Sendable {
    let requestId: UUID
    var reservation: PhotoReservation?
    var isReady = false
    var recognitionRequestId: UUID?
    var recognitionRetryRequired: Bool?

    func validate(owner: DraftOwner) throws {
        if let reservation { try reservation.validate(owner: owner) }
        guard !isReady || reservation != nil, recognitionRequestId == nil || isReady,
            recognitionRetryRequired != true || recognitionRequestId != nil
        else { throw DraftStorageFailure.invalidData }
    }
}

struct RecognitionRequestIdentity: Equatable, Sendable {
    let photoId: UUID
    let requestId: UUID
}

enum PhotoUploadStage: Equatable {
    case reserving, uploading, validating
}

/// Session-scoped capability. The caller persists reservation IDs before upload and retries explicitly.
@MainActor
protocol PhotoService: Sendable {
    var owner: DraftOwner { get }
    func reserve(requestID: UUID) async throws -> PhotoReservation
    func upload(_ draft: ImageDraft, to reservation: PhotoReservation) async throws
    func complete(_ reservation: PhotoReservation) async throws
    func download(photoID: UUID) async throws -> Data
    func discard(photoID: UUID) async throws
}
