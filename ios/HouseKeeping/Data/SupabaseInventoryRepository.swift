import Foundation
import Supabase

/// Recreate after any sign-in/sign-out. Scope is immutable even when the auth service changes account.
@MainActor
final class SupabaseInventoryRepository: InventoryRepository {
    private let auth: SupabaseAuthService
    private let accountID: UUID
    private let householdID: UUID
    private let generation: UUID

    init(auth: SupabaseAuthService, accountID: UUID, householdID: UUID) {
        self.auth = auth
        self.accountID = accountID
        self.householdID = householdID
        generation = auth.inventoryGeneration
    }

    func search(_ query: ItemQuery) async throws -> ItemPage {
        try query.validate()
        guard query.householdId == householdID else { throw InventoryFailure.notFound }
        let page: ItemPage = try await request(.search, input: query)
        guard page.data.count <= query.limit, Set(page.data.map(\.id)).count == page.data.count,
            page.nextOffset == nil
                || (page.nextOffset == query.offset + query.limit
                    && page.data.count == query.limit && query.offset + query.limit <= 10000)
        else { throw InventoryFailure.invalidResponse }
        for item in page.data { try validate(item) }
        return page
    }

    func get(id: UUID) async throws -> Item {
        let item: Item = try await request(.get, input: ItemID(id: id))
        try validate(item, expectedID: id)
        return item
    }

    func create(_ input: CreateItemInput) async throws -> Item {
        try input.fields.validate()
        guard input.householdId == householdID else { throw InventoryFailure.notFound }
        let item: Item = try await request(.create, input: input)
        try validate(item)
        return item  // A replay can legitimately return an item edited since its initial creation.
    }

    func update(_ input: UpdateItemInput) async throws -> Item {
        try input.fields.validate()
        try ItemVersion.validate(input.expectedVersion)
        // An update increments the version. Do not commit a value the contract cannot represent.
        guard input.expectedVersion < 9_007_199_254_740_991 else { throw InventoryFailure.validation }
        let item: Item = try await request(.update, input: input)
        try validate(item, expectedID: input.id)
        guard item.version == input.expectedVersion + 1 else { throw InventoryFailure.invalidResponse }
        return item
    }

    func delete(id: UUID, expectedVersion: Int64) async throws {
        try ItemVersion.validate(expectedVersion)
        do {
            _ = try await auth.inventoryRequest(
                .delete, input: ItemDeletion(id: id, expectedVersion: expectedVersion),
                accountID: accountID, generation: generation)
        } catch { throw Self.normalize(error) }
    }

    func removePhoto(itemID: UUID, expectedVersion: Int64) async throws -> Item {
        try ItemVersion.validate(expectedVersion)
        guard expectedVersion < 9_007_199_254_740_991 else { throw InventoryFailure.validation }
        let item: Item = try await request(
            .removePhoto, input: PhotoRemoval(itemId: itemID, expectedVersion: expectedVersion))
        try validate(item, expectedID: itemID)
        // A photo-free item is an acknowledged no-op; a removed photo increments once.
        guard item.photoId == nil, item.version == expectedVersion || item.version == expectedVersion + 1 else {
            throw InventoryFailure.invalidResponse
        }
        return item
    }

    private func request<Input: Encodable & Sendable, Output: Decodable>(
        _ operation: InventoryRPC, input: Input
    ) async throws -> Output {
        let data: Data
        do {
            data = try await auth.inventoryRequest(
                operation, input: input, accountID: accountID, generation: generation)
        } catch { throw Self.normalize(error) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let string = try decoder.singleValueContainer().decode(String.self)
                if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
                    return date
                }
                return try Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string)
            }
            return try decoder.decode(Output.self, from: data)
        } catch { throw InventoryFailure.invalidResponse }
    }

    private func validate(_ item: Item, expectedID: UUID? = nil) throws {
        guard item.householdId == householdID, expectedID == nil || item.id == expectedID else {
            throw InventoryFailure.invalidResponse
        }
        do {
            try item.fields.validate()
            try ItemVersion.validate(item.version)
        } catch { throw InventoryFailure.invalidResponse }
    }

    private static func normalize(_ error: any Error) -> any Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if let failure = error as? InventoryFailure { return failure }
        if let failure = error as? AuthenticationFailure {
            switch failure {
            case .protectedStorage: return InventoryFailure.protectedStorage
            case .sessionExpired, .invalidCredentials, .emailUnverified: return InventoryFailure.unauthenticated
            case .noHousehold: return InventoryFailure.notFound
            case .unavailable: return InventoryFailure.unavailable
            }
        }
        if error is AuthError { return normalize(SupabaseAuthService.normalize(error)) }
        if let http = error as? HTTPError {
            switch http.response.statusCode {
            case 401: return InventoryFailure.unauthenticated
            case 403: return InventoryFailure.forbidden
            default: return InventoryFailure.unavailable
            }
        }
        if let database = error as? PostgrestError {
            switch database.code {
            case "PT401", "PGRST301", "PGRST302", "PGRST303": return InventoryFailure.unauthenticated
            case "42501": return InventoryFailure.forbidden
            case "PT404": return InventoryFailure.notFound
            case "PT409":
                return database.message == "PHOTO_NOT_READY"
                    ? InventoryFailure.photoNotReady : InventoryFailure.conflict
            case "PT422": return InventoryFailure.validation
            default: break
            }
        }
        return InventoryFailure.unavailable  // Never forward SQL, request payloads, tokens, or URLs.
    }

    private struct ItemID: Encodable { let id: UUID }
    private struct PhotoRemoval: Encodable {
        let itemId: UUID
        let expectedVersion: Int64
    }
    private struct ItemDeletion: Encodable {
        let id: UUID
        let expectedVersion: Int64
    }
}
