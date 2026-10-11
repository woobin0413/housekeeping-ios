import Foundation
import Observation

struct AccountIdentity: Equatable, Sendable {
    let id: UUID
    let email: String
}

struct Household: Decodable, Equatable, Sendable {
    let householdId: UUID
    let name: String
}

enum AuthenticationFailure: Error, Equatable {
    case invalidCredentials, emailUnverified, sessionExpired, noHousehold, protectedStorage, unavailable
}

enum SignOutResult: Equatable { case complete, localOnly }

@MainActor
protocol AuthenticationService {
    func restore() async throws -> AccountIdentity?
    func signIn(email: String, password: String) async throws -> AccountIdentity
    func household() async throws -> Household
    func signOut() async throws -> SignOutResult
}

/// Own this once at the app root. Views receive identity, never tokens or passwords.
@MainActor @Observable
final class AuthSession {
    enum State: Equatable {
        case signedOut
        case checking
        case ready(AccountIdentity, Household)
        case needsHousehold(AccountIdentity)
        case blocked(AuthenticationFailure)
    }

    private(set) var state: State = .signedOut
    private(set) var isBusy = false
    private(set) var failure: AuthenticationFailure?
    private(set) var signOutWasLocalOnly = false
    private let service: any AuthenticationService

    init(service: any AuthenticationService) { self.service = service }

    func restore() async {
        guard !isBusy else { return }
        isBusy = true
        state = .checking  // Hide previous-account data until membership is revalidated.
        failure = nil
        defer { isBusy = false }
        do {
            guard let identity = try await service.restore() else {
                state = .signedOut
                return
            }
            try await loadHousehold(for: identity)
        } catch {
            handle(error)
        }
    }

    func signIn(email: String, password: String) async {
        guard !isBusy, state == .signedOut else { return }
        isBusy = true
        failure = nil
        signOutWasLocalOnly = false
        defer { isBusy = false }
        do {
            let identity = try await service.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            try await loadHousehold(for: identity)
        } catch {
            handle(error)
        }
    }

    func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        state = .checking
        failure = nil
        defer { isBusy = false }
        do {
            signOutWasLocalOnly = try await service.signOut() == .localOnly
            state = .signedOut
        } catch {
            // Do not claim successful sign-out if device credential deletion failed.
            handle(error)
        }
    }

    private func loadHousehold(for identity: AccountIdentity) async throws {
        do {
            state = .ready(identity, try await service.household())
        } catch AuthenticationFailure.noHousehold {
            state = .needsHousehold(identity)
        }
    }

    private func handle(_ error: any Error) {
        let normalized = error as? AuthenticationFailure ?? .unavailable
        failure = normalized
        switch normalized {
        case .invalidCredentials, .emailUnverified, .sessionExpired:
            state = .signedOut
        default:
            state = .blocked(normalized)
        }
    }
}
