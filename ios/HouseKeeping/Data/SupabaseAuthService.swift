import Foundation
import Supabase

@MainActor
final class SupabaseAuthService: AuthenticationService {
    private let client: SupabaseClient
    private let storage: any AuthLocalStorage
    private let sessionKey = "session"
    private let configuration: AppConfiguration
    private let transport: URLSession
    private(set) var inventoryGeneration = UUID()

    convenience init(configuration: AppConfiguration, bundleID: String) {
        self.init(
            configuration: configuration,
            storage: KeychainSessionStorage(projectURL: configuration.url, bundleID: bundleID),
            transport: .shared)
    }

    // Explicit injection keeps SDK transport tests offline and previews independent of Keychain.
    init(configuration: AppConfiguration, storage: any AuthLocalStorage, transport: URLSession) {
        self.storage = storage
        self.configuration = configuration
        self.transport = transport
        client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey,
            options: .init(
                auth: .init(
                    storage: storage, storageKey: sessionKey,
                    // Refresh on restore / authenticated operations, so storage failures are observable.
                    autoRefreshToken: false, emitLocalSessionAsInitialSession: false
                ), global: .init(session: transport, logger: nil))
        )
    }

    func restore() async throws -> AccountIdentity? {
        do {
            guard try readSession() != nil else { return nil }
            return try await refreshedIdentity()
        } catch {
            throw Self.normalize(error)
        }
    }

    func signIn(email: String, password: String) async throws -> AccountIdentity {
        inventoryGeneration = UUID()
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            try persist(session)
            return identity(session)
        } catch {
            throw Self.normalize(error)
        }
    }

    func household() async throws -> Household {
        do {
            _ = try await refreshedIdentity()
            let household: Household = try await client.rpc("get_household").execute().value
            guard !household.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                household.name.count <= 100
            else { throw AuthenticationFailure.unavailable }
            return household
        } catch {
            throw Self.normalize(error)
        }
    }

    func signOut() async throws -> SignOutResult {
        inventoryGeneration = UUID()
        // Read first to surface Keychain errors the SDK otherwise swallows. Keep the token
        // available until the SDK captures it for server revocation.
        _ = try readSession()
        var result = SignOutResult.complete
        do { try await client.auth.signOut(scope: .local) } catch { result = .localOnly }
        try clearStorage()
        return result
    }

    /// A narrow data-layer capability. Tokens never leave this service or enter domain/view models.
    func inventoryRequest<Input: Encodable & Sendable>(
        _ operation: InventoryRPC, input: Input, accountID: UUID, generation: UUID
    ) async throws -> Data {
        try Task.checkCancellation()
        guard generation == inventoryGeneration, try readSession()?.user.id == accountID
        else { throw InventoryFailure.unauthenticated }
        let session = try await client.auth.session
        try Task.checkCancellation()
        guard generation == inventoryGeneration, session.user.id == accountID,
            try readSession()?.user.id == accountID
        else { throw InventoryFailure.unauthenticated }
        try persist(session)

        // Pin this request to the verified account. SupabaseClient's default request adapter
        // fetches the *current* token asynchronously, which could belong to a newly signed-in user.
        let database = PostgrestClient(
            url: configuration.url.appending(path: "rest/v1"),
            headers: ["apikey": configuration.publishableKey, "Authorization": "Bearer \(session.accessToken)"],
            fetch: { [transport] request in try await transport.data(for: request) })
        let response: PostgrestResponse<Void> = try await database.rpc(
            operation.rawValue, params: InventoryArguments(input: input)
        ).retry(enabled: false).execute()
        try Task.checkCancellation()
        guard generation == inventoryGeneration, try readSession()?.user.id == accountID
        else { throw InventoryFailure.unauthenticated }
        return response.data
    }

    private func refreshedIdentity() async throws -> AccountIdentity {
        let session = try await client.auth.session
        try persist(session)
        return identity(session)
    }

    /// Freeze the verified credential per request; never follow redirects or retain photo responses in URLCache.
    func photoRequest(
        _ endpoint: PhotoEndpoint, body: Data?, accountID: UUID, generation: UUID
    ) async throws -> (status: Int, data: Data) {
        try Task.checkCancellation()
        guard generation == inventoryGeneration, try readSession()?.user.id == accountID
        else { throw PhotoFailure.unauthenticated }
        let session = try await client.auth.session
        guard generation == inventoryGeneration, session.user.id == accountID,
            try readSession()?.user.id == accountID
        else { throw PhotoFailure.unauthenticated }
        try persist(session)
        var url = configuration.url.appending(path: endpoint.path)
        if case .metadata(let id) = endpoint {
            url.append(queryItems: [
                .init(name: "select", value: "id,household_id,uploader_user_id,object_key,state,byte_size,checksum"),
                .init(name: "id", value: "eq.\(id)"), .init(name: "limit", value: "1"),
            ])
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = endpoint.method
        request.httpBody = body
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if case .upload = endpoint {
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.setValue("false", forHTTPHeaderField: "x-upsert")
        }
        let response = try await Self.readPhotoResponse(
            request: request, transport: transport, limit: endpoint.maximumResponseBytes)
        try Task.checkCancellation()
        guard generation == inventoryGeneration, try readSession()?.user.id == accountID
        else { throw PhotoFailure.unauthenticated }
        return response
    }

    /// Recognition receives only the two UUIDs; the Edge Function resolves and downloads the private photo.
    func recognitionRequest(
        body: Data, accountID: UUID, generation: UUID
    ) async throws -> (status: Int, data: Data) {
        try Task.checkCancellation()
        guard body.count <= 4_096 else { throw RecognitionFailure.validation }
        guard generation == inventoryGeneration, try readSession()?.user.id == accountID
        else { throw RecognitionFailure.unauthenticated }
        let session = try await client.auth.session
        guard generation == inventoryGeneration, session.user.id == accountID,
            try readSession()?.user.id == accountID
        else { throw RecognitionFailure.unauthenticated }
        try persist(session)
        let url = configuration.url.appending(path: "functions/v1/recognitions")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await Self.readPhotoResponse(request: request, transport: transport, limit: 64 * 1_024)
        try Task.checkCancellation()
        guard generation == inventoryGeneration, try readSession()?.user.id == accountID
        else { throw RecognitionFailure.unauthenticated }
        return response
    }

    /// Keep bounded stream assembly off the main actor even when URLSession already buffered the bytes.
    private nonisolated static func readPhotoResponse(
        request: URLRequest, transport: URLSession, limit: Int
    ) async throws -> (status: Int, data: Data) {
        let (bytes, response) = try await transport.bytes(for: request, delegate: PrivatePhotoRequestDelegate())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse,
            response.expectedContentLength <= limit
        else { throw PhotoFailure.invalidResponse }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < limit else { throw PhotoFailure.invalidResponse }
            data.append(byte)
        }
        return (http.statusCode, data)
    }

    private func identity(_ session: Session) -> AccountIdentity {
        AccountIdentity(id: session.user.id, email: session.user.email ?? "")
    }

    private func readSession() throws -> Session? {
        do {
            guard let data = try storage.retrieve(key: sessionKey) else { return nil }
            return try JSONDecoder().decode(Session.self, from: data)
        } catch { throw AuthenticationFailure.protectedStorage }
    }

    private func persist(_ session: Session) throws {
        do {
            try storage.store(key: sessionKey, value: JSONEncoder().encode(session))
            guard let stored = try readSession(), stored.user.id == session.user.id,
                stored.refreshToken == session.refreshToken
            else { throw AuthenticationFailure.protectedStorage }
        } catch { throw AuthenticationFailure.protectedStorage }
    }

    private func clearStorage() throws {
        do {
            try storage.remove(key: sessionKey)
            guard try storage.retrieve(key: sessionKey) == nil else { throw AuthenticationFailure.protectedStorage }
        } catch { throw AuthenticationFailure.protectedStorage }
    }

    static func normalize(_ error: any Error) -> AuthenticationFailure {
        if let failure = error as? AuthenticationFailure { return failure }
        if let auth = error as? AuthError {
            switch auth.errorCode {
            case .invalidCredentials: return .invalidCredentials
            case .emailNotConfirmed: return .emailUnverified
            case .sessionNotFound, .refreshTokenNotFound, .refreshTokenAlreadyUsed: return .sessionExpired
            default: return .unavailable
            }
        }
        if let database = error as? PostgrestError {
            switch database.code {
            case "PT404": return .noHousehold
            case "PT401", "PGRST301", "PGRST303": return .sessionExpired
            default: return .unavailable
            }
        }
        return .unavailable  // Never expose SDK response bodies, credentials, or URLs.
    }
}

private final class PrivatePhotoRequestDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) { completionHandler(nil) }
}

enum InventoryRPC: String {
    case search = "search_items"
    case get = "get_item"
    case create = "create_item"
    case update = "update_item"
    case delete = "delete_item"
    case removePhoto = "remove_item_photo"
}

private struct InventoryArguments<Input: Encodable & Sendable>: Encodable {
    let input: Input
    private enum CodingKeys: String, CodingKey { case input = "p_input" }
}
