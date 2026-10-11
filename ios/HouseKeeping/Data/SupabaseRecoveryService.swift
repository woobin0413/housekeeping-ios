import Foundation
import Supabase

/// An isolated client/Keychain namespace: a recovery session never becomes an inventory session.
@MainActor
final class SupabaseRecoveryService: PasswordRecoveryService {
    private let client: SupabaseClient
    private let storage: any AuthLocalStorage
    private let contextKey = "pending-recovery"
    private let sessionKey = "recovery-session"
    private let verifierKey = "recovery-session-code-verifier"

    convenience init(configuration: AppConfiguration, bundleID: String) {
        self.init(
            configuration: configuration,
            storage: KeychainSessionStorage(projectURL: configuration.url, bundleID: bundleID + ".recovery"),
            transport: .shared)
    }

    init(configuration: AppConfiguration, storage: any AuthLocalStorage, transport: URLSession) {
        self.storage = storage
        client = SupabaseClient(
            supabaseURL: configuration.url, supabaseKey: configuration.publishableKey,
            options: .init(
                auth: .init(
                    storage: storage, storageKey: sessionKey,
                    flowType: .pkce, autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: false),
                global: .init(session: transport, logger: nil)))
    }

    func restoreRecovery() async throws -> RecoveryStatus? {
        guard var context = try await validContext() else { return nil }
        let storedSession = try read(sessionKey)
        guard context.userID != nil || storedSession != nil else { return .awaitingEmail }
        // Recover a crash after SDK session persistence but before our context was updated.
        do {
            let user = try await verifiedUser(context)
            context.userID = user.id
            try writeContext(context)
            try remove(verifierKey)
        } catch {
            let failure = Self.normalize(error)
            if failure == .invalidLink { _ = try await clearRecovery() }
            throw failure
        }
        return .passwordEntry(email: context.email)
    }

    func requestRecovery(email: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254, email.contains("@"),
            !email.contains(where: { $0.isWhitespace || $0.isNewline })
        else { throw RecoveryFailure.invalidEmail }
        _ = try await clearRecovery()
        let context = PendingRecovery(email: email, requestedAt: Date())
        try writeContext(context)
        do {
            try await client.auth.resetPasswordForEmail(email, redirectTo: AuthCallbackHandler.redirectURL)
            // The SDK catches verifier-storage errors. Do not claim a usable request without it.
            guard let verifier = try read(verifierKey), (43...128).contains(verifier.count) else {
                throw RecoveryFailure.protectedStorage
            }
        } catch {
            let failure = Self.normalize(error)
            _ = try await clearRecovery()
            throw failure
        }
    }

    func acceptRecovery(url: URL) async throws -> String {
        let code = try AuthCallbackHandler.recoveryCode(from: url)
        guard var context = try await validContext(), context.userID == nil,
            let verifier = try read(verifierKey), (43...128).contains(verifier.count)
        else {
            throw RecoveryFailure.invalidLink
        }
        var exchanged = false
        do {
            let session = try await client.auth.exchangeCodeForSession(authCode: code)
            exchanged = true
            guard matches(session.user, context: context) else {
                _ = try await clearRecovery()
                throw RecoveryFailure.invalidLink
            }
            try write(sessionKey, value: JSONEncoder().encode(session))
            context.userID = session.user.id
            try writeContext(context)
            try remove(verifierKey)
            return context.email
        } catch {
            let failure = Self.normalize(error)
            if exchanged { _ = try await clearRecovery() }
            throw failure
        }
    }

    func changePassword(_ password: String) async throws {
        guard password.count >= 12, password.utf8.count <= 72 else { throw RecoveryFailure.invalidPassword }
        guard let context = try await validContext(), context.userID != nil else {
            throw RecoveryFailure.invalidLink
        }
        do {
            _ = try await verifiedUser(context)
            let user = try await client.auth.update(user: .init(password: password))
            guard matches(user, context: context) else { throw RecoveryFailure.invalidLink }
        } catch { throw Self.normalize(error) }
    }

    func clearRecovery() async throws -> SignOutResult {
        // Validate readability before SDK logout, which silently ignores storage errors.
        _ = try read(sessionKey)
        var result = SignOutResult.complete
        do { try await client.auth.signOut(scope: .local) } catch { result = .localOnly }
        // Always try every key, even if deletion of another key failed.
        var failed = false
        for key in [contextKey, verifierKey, sessionKey] {
            do { try remove(key) } catch { failed = true }
        }
        if failed { throw RecoveryFailure.protectedStorage }
        return result
    }

    private func verifiedUser(_ context: PendingRecovery) async throws -> User {
        do {
            guard try read(sessionKey) != nil else { throw RecoveryFailure.invalidLink }
            let session = try await client.auth.session
            try write(sessionKey, value: JSONEncoder().encode(session))
            let user = try await client.auth.user()
            guard matches(user, context: context) else { throw RecoveryFailure.invalidLink }
            return user
        } catch { throw Self.normalize(error) }
    }

    private func matches(_ user: User, context: PendingRecovery) -> Bool {
        !user.isAnonymous && user.email?.lowercased() == context.email
            && (context.userID == nil || context.userID == user.id)
    }

    private func readContext() throws -> PendingRecovery? {
        guard let data = try read(contextKey) else { return nil }
        guard let context = try? JSONDecoder().decode(PendingRecovery.self, from: data) else {
            throw RecoveryFailure.protectedStorage
        }
        return context
    }

    private func validContext() async throws -> PendingRecovery? {
        guard let context = try readContext() else {
            if try read(sessionKey) != nil || read(verifierKey) != nil { _ = try await clearRecovery() }
            return nil
        }
        guard context.isValid(at: Date()) else {
            _ = try await clearRecovery()
            throw RecoveryFailure.invalidLink
        }
        return context
    }

    private func writeContext(_ context: PendingRecovery) throws {
        try write(contextKey, value: JSONEncoder().encode(context))
    }

    private func read(_ key: String) throws -> Data? {
        do { return try storage.retrieve(key: key) } catch { throw RecoveryFailure.protectedStorage }
    }

    private func write(_ key: String, value: Data) throws {
        do {
            try storage.store(key: key, value: value)
            guard try storage.retrieve(key: key) == value else { throw RecoveryFailure.protectedStorage }
        } catch { throw RecoveryFailure.protectedStorage }
    }

    private func remove(_ key: String) throws {
        do {
            try storage.remove(key: key)
            guard try storage.retrieve(key: key) == nil else { throw RecoveryFailure.protectedStorage }
        } catch { throw RecoveryFailure.protectedStorage }
    }

    private static func normalize(_ error: any Error) -> RecoveryFailure {
        if let failure = error as? RecoveryFailure { return failure }
        if let auth = error as? AuthError {
            switch auth.errorCode {
            case .weakPassword, .samePassword: return .invalidPassword
            case .flowStateNotFound, .flowStateExpired, .badCodeVerifier, .sessionNotFound,
                .refreshTokenNotFound, .refreshTokenAlreadyUsed, .otpExpired:
                return .invalidLink
            default: return .unavailable
            }
        }
        return .unavailable
    }
}
