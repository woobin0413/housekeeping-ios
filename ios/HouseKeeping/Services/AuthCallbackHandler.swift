import Foundation

enum RecoveryFailure: Error, Equatable {
    case invalidLink, invalidEmail, invalidPassword, unavailable, protectedStorage
}

enum AuthCallbackHandler {
    static let redirectURL = URL(string: "housekeeping://auth/recovery")!

    static func recoveryCode(from url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "housekeeping", parts.host == "auth", parts.path == "/recovery",
            parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
            let query = parts.queryItems, query.count == 1,
            query[0].name == "code", let code = query[0].value,
            code.range(of: #"\A[A-Za-z0-9_-]{1,2048}\z"#, options: .regularExpression) != nil
        else { throw RecoveryFailure.invalidLink }
        return code
    }
}

struct PendingRecovery: Codable, Equatable, Sendable {
    let email: String
    let requestedAt: Date
    var userID: UUID?

    func isValid(at now: Date) -> Bool {
        let age = now.timeIntervalSince(requestedAt)
        return age >= 0 && age < 3600
    }
}

enum RecoveryStatus: Equatable, Sendable {
    case awaitingEmail
    case passwordEntry(email: String)
}

@MainActor
protocol PasswordRecoveryService {
    func restoreRecovery() async throws -> RecoveryStatus?
    func requestRecovery(email: String) async throws
    func acceptRecovery(url: URL) async throws -> String
    func changePassword(_ password: String) async throws
    func clearRecovery() async throws -> SignOutResult
}
