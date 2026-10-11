import CryptoKit
import Foundation

/// All requests use the account generation captured at construction. No disk or shared image cache.
@MainActor
final class SupabasePhotoService: PhotoService {
    let owner: DraftOwner
    private let auth: SupabaseAuthService
    private let generation: UUID

    init(auth: SupabaseAuthService, owner: DraftOwner) {
        self.auth = auth
        self.owner = owner
        generation = auth.inventoryGeneration
    }

    func reserve(requestID: UUID) async throws -> PhotoReservation {
        let body = try JSONEncoder().encode(ReservationInput(householdId: owner.householdID, requestId: requestID))
        let response = try await request(.reserve, body: body)
        let reservation = try decode(PhotoReservation.self, from: response)
        try reservation.validate(owner: owner)
        guard reservation.expiresAt > Date() else { throw PhotoFailure.expired }
        return reservation
    }

    func upload(_ draft: ImageDraft, to reservation: PhotoReservation) async throws {
        try reservation.validate(owner: owner)
        guard draft.owner == owner else { throw PhotoFailure.validation }
        guard reservation.expiresAt > Date() else { throw PhotoFailure.expired }
        do { try draft.validateStorage() } catch { throw PhotoFailure.validation }
        _ = try await request(.upload(reservation.objectKey), body: draft.jpegData)
    }

    func complete(_ reservation: PhotoReservation) async throws {
        try reservation.validate(owner: owner)
        guard reservation.expiresAt > Date() else { throw PhotoFailure.expired }
        let result = try decode(
            Completion.self, from: await request(.complete(reservation.photoId), body: Data("{}".utf8)))
        guard result.photoId == reservation.photoId, result.state == "READY" else {
            throw PhotoFailure.invalidResponse
        }
    }

    func download(photoID: UUID) async throws -> Data {
        let rows = try decode([PhotoRow].self, from: await request(.metadata(photoID)))
        guard !rows.isEmpty else { throw PhotoFailure.notFound }
        guard rows.count == 1, let row = rows.first,
            row.id == photoID, row.householdId == owner.householdID, row.state == "ATTACHED",
            row.objectKey
                == PhotoReservation.objectKey(
                    householdID: owner.householdID, uploaderID: row.uploaderUserId, photoID: photoID),
            (1...PhotoPreparation.maximumOutputBytes).contains(row.byteSize),
            row.checksum.count == 64
        else { throw PhotoFailure.invalidResponse }
        let data = try await request(.download(row.objectKey))
        guard data.count == row.byteSize,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == row.checksum
        else { throw PhotoFailure.invalidResponse }
        return data
    }

    func discard(photoID: UUID) async throws {
        _ = try await request(.discard(photoID))
    }

    private func request(_ endpoint: PhotoEndpoint, body: Data? = nil) async throws -> Data {
        do {
            let response = try await auth.photoRequest(
                endpoint, body: body, accountID: owner.accountID, generation: generation)
            guard (200..<300).contains(response.status) else {
                let code = (try? JSONDecoder().decode(ServerFailure.self, from: response.data))?.code
                switch response.status {
                case 401: throw PhotoFailure.unauthenticated
                case 403: throw PhotoFailure.forbidden
                case 404: throw PhotoFailure.notFound
                case 409:
                    if code == "RESERVATION_EXPIRED" { throw PhotoFailure.expired }
                    if code == "UPLOAD_INCOMPLETE" { throw PhotoFailure.uploadIncomplete }
                    throw PhotoFailure.conflict
                case 400, 422: throw PhotoFailure.validation
                default: throw PhotoFailure.unavailable
                }
            }
            return response.data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as PhotoFailure {
            throw error
        } catch let error as AuthenticationFailure {
            switch error {
            case .protectedStorage: throw PhotoFailure.protectedStorage
            case .sessionExpired, .invalidCredentials, .emailUnverified: throw PhotoFailure.unauthenticated
            default: throw PhotoFailure.unavailable
            }
        } catch { throw PhotoFailure.unavailable }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                    return date
                }
                return try Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value)
            }
            return try decoder.decode(type, from: data)
        } catch { throw PhotoFailure.invalidResponse }
    }

    private struct ReservationInput: Encodable {
        let householdId: UUID
        let requestId: UUID
    }
    private struct Completion: Decodable {
        let photoId: UUID
        let state: String
    }
    private struct ServerFailure: Decodable { let code: String }
    private struct PhotoRow: Decodable {
        let id: UUID
        let householdId: UUID
        let uploaderUserId: UUID
        let objectKey: String
        let state: String
        let byteSize: Int
        let checksum: String

        private enum CodingKeys: String, CodingKey {
            case id
            case householdId = "household_id"
            case uploaderUserId = "uploader_user_id"
            case objectKey = "object_key"
            case state
            case byteSize = "byte_size"
            case checksum
        }
    }
}

/// Only these same-project routes can receive the authenticated photo capability.
enum PhotoEndpoint {
    case reserve
    case complete(UUID)
    case upload(String)
    case metadata(UUID)
    case download(String)
    case discard(UUID)

    var path: String {
        switch self {
        case .reserve: "functions/v1/media/photos"
        case .complete(let id): "functions/v1/media/photos/\(id)/completion"
        case .discard(let id): "functions/v1/media/photos/\(id)"
        case .metadata: "rest/v1/photos"
        case .upload(let key), .download(let key): "storage/v1/object/purchase-photos/\(key)"
        }
    }

    var method: String {
        switch self {
        case .metadata, .download: "GET"
        case .discard: "DELETE"
        default: "POST"
        }
    }

    var maximumResponseBytes: Int {
        if case .download = self { return PhotoPreparation.maximumOutputBytes }
        return 64 * 1024
    }
}
