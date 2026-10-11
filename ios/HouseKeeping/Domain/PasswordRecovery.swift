import Foundation
import Observation

@MainActor @Observable
final class PasswordRecovery {
    enum State: Equatable {
        case inactive, requestEmail, awaitingEmail
        case passwordEntry(email: String)
        case passwordChanged
    }
    private(set) var state: State = .inactive
    private(set) var isBusy = false
    private(set) var failure: RecoveryFailure?
    private(set) var needsCleanup = false
    private(set) var signOutWasLocalOnly = false
    private let service: any PasswordRecoveryService
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(service: any PasswordRecoveryService) { self.service = service }

    func begin() {
        guard !isBusy, state == .inactive else { return }
        state = .requestEmail
        failure = nil
    }

    func restore() async {
        guard !isBusy, state != .passwordChanged else { return }
        isBusy = true
        defer { finishOperation() }
        do {
            switch try await service.restoreRecovery() {
            case .none: if state != .requestEmail { state = .inactive }
            case .awaitingEmail: state = .awaitingEmail
            case .passwordEntry(let email): state = .passwordEntry(email: email)
            }
            failure = nil
        } catch {
            state = .requestEmail
            failure = error as? RecoveryFailure ?? .unavailable
        }
    }

    func request(email: String) async {
        guard !isBusy, state == .requestEmail || state == .awaitingEmail else { return }
        isBusy = true
        failure = nil
        defer { finishOperation() }
        do {
            try await service.requestRecovery(email: email)
            state = .awaitingEmail
        } catch { failure = error as? RecoveryFailure ?? .unavailable }
    }

    func accept(url: URL) async {
        // A deep link is an external event, not a disabled button tap. Never drop it
        // while a request, restoration, or cleanup is using the same recovery client.
        while isBusy { await withCheckedContinuation { idleWaiters.append($0) } }
        guard !Task.isCancelled else { return }
        guard state != .passwordChanged else {
            failure = .invalidLink
            return
        }
        isBusy = true
        failure = nil
        defer { finishOperation() }
        do { state = .passwordEntry(email: try await service.acceptRecovery(url: url)) } catch {
            if state == .inactive { state = .requestEmail }
            failure = error as? RecoveryFailure ?? .unavailable
        }
    }

    func save(password: String, confirmation: String) async {
        guard !isBusy, case .passwordEntry = state else { return }
        guard password == confirmation else {
            failure = .invalidPassword
            return
        }
        isBusy = true
        failure = nil
        defer { finishOperation() }
        do {
            try await service.changePassword(password)
            state = .passwordChanged  // A cleanup failure must never ask to change it again.
            needsCleanup = true
            signOutWasLocalOnly = try await service.clearRecovery() == .localOnly
            needsCleanup = false
        } catch { failure = error as? RecoveryFailure ?? .unavailable }
    }

    func close() async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do {
            signOutWasLocalOnly = try await service.clearRecovery() == .localOnly
            needsCleanup = false
            state = .inactive
            failure = nil
        } catch { failure = error as? RecoveryFailure ?? .unavailable }
    }

    private func finishOperation() {
        isBusy = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
