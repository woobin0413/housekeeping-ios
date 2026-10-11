import SwiftUI

struct PasswordRecoveryView: View {
    let recovery: PasswordRecovery
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @FocusState private var focus: Field?
    private enum Field { case email, password, confirmation }

    var body: some View {
        AccountScreen(title: "Make yourself at home.", subtitle: "Set up or reset your password securely.") {
            VStack(alignment: .leading, spacing: 16) {
                switch recovery.state {
                case .inactive, .requestEmail, .awaitingEmail:
                    if recovery.state == .awaitingEmail {
                        Text(
                            "If this account exists, a recovery email is on its way. Open its link on this iPhone within an hour."
                        )
                        .accessibilityIdentifier("recoveryEmailSent")
                    }
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .email).submitLabel(.send).onSubmit(request)
                        .accountField().accessibilityIdentifier("recoveryEmail")
                    Button("Send recovery email", action: request).buttonStyle(PrimaryButtonStyle())
                        .disabled(email.isEmpty).accessibilityIdentifier("sendRecovery")
                case .passwordEntry(let address):
                    Text("New password for \(address)").accessibilityIdentifier("recoveryAccount")
                    SecureField("New password", text: $password).textContentType(.newPassword)
                        .focused($focus, equals: .password).submitLabel(.next)
                        .onSubmit { focus = .confirmation }.accountField().accessibilityIdentifier("newPassword")
                    SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                        .focused($focus, equals: .confirmation).submitLabel(.done).onSubmit(save)
                        .accountField().accessibilityIdentifier("confirmPassword")
                    Text("Use at least 12 characters (up to 72 UTF-8 bytes). Both entries must match.")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                    Button("Save new password", action: save).buttonStyle(PrimaryButtonStyle())
                        .disabled(password.isEmpty || confirmation.isEmpty).accessibilityIdentifier("savePassword")
                case .passwordChanged:
                    Text("Password updated. Sign in with your new password to access your home.")
                        .accessibilityIdentifier("passwordChanged")
                    if recovery.needsCleanup {
                        Text("The password changed, but secure session cleanup needs another try.")
                    }
                }
                if let failure = recovery.failure {
                    Text(failure.message).font(.callout).accessibilityIdentifier("recoveryError")
                }
                if recovery.isBusy { ProgressView("Please wait…") }
                Button(recovery.needsCleanup ? "Retry secure cleanup" : "Back to sign in", action: close)
                    .frame(minHeight: 44).accessibilityIdentifier("closeRecovery")
            }
            .disabled(recovery.isBusy)
        }
        .onDisappear {
            password = ""
            confirmation = ""
        }
    }

    private func request() {
        focus = nil
        Task { await recovery.request(email: email) }
    }
    private func save() {
        focus = nil
        let submitted = password
        let repeated = confirmation
        password = ""
        confirmation = ""
        Task { await recovery.save(password: submitted, confirmation: repeated) }
    }
    private func close() {
        focus = nil
        password = ""
        confirmation = ""
        Task { await recovery.close() }
    }
}

extension RecoveryFailure {
    var message: String {
        switch self {
        case .invalidLink: "This recovery link is invalid or expired. Request a new one on this iPhone."
        case .invalidEmail: "Enter a valid email address."
        case .invalidPassword:
            "Use a different password with at least 12 characters, no more than 72 UTF-8 bytes, and matching confirmation."
        case .unavailable: "We couldn’t finish the request. Check your connection and try again."
        case .protectedStorage: "Protected storage is unavailable. Unlock this iPhone and retry."
        }
    }
}
