import SwiftUI

struct SignInView: View {
    let connection: AppConnection
    private var auth: AuthSession { connection.auth }
    private var recovery: PasswordRecovery { connection.recovery }
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    var body: some View {
        AccountScreen(title: "A home for everything.", subtitle: "Sign in to the home you share.") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .email).submitLabel(.next)
                    .onSubmit { focus = .password }
                    .accountField().accessibilityIdentifier("signInEmail")
                SecureField("Password", text: $password)
                    .textContentType(.password).focused($focus, equals: .password)
                    .submitLabel(.go).onSubmit(signIn)
                    .accountField().accessibilityIdentifier("signInPassword")
                if let failure = auth.failure {
                    Text(failure.message).font(.callout).accessibilityIdentifier("signInError")
                }
                if auth.signOutWasLocalOnly {
                    Text("Signed out on this iPhone. The server could not confirm session revocation.").font(.callout)
                }
                Button(auth.isBusy ? "Signing in…" : "Sign in", action: signIn)
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("signInButton")
                    .disabled(
                        auth.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty
                    )
                Button("Set up or reset password") {
                    password = ""
                    focus = nil
                    recovery.begin()
                }
                .frame(minHeight: 44).accessibilityIdentifier("beginRecovery")
                .disabled(auth.isBusy)
                Text("Just the two of you. Accounts are set up privately; there’s no public registration.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            .disabled(auth.isBusy)
        }
        .onDisappear { password = "" }
    }

    private func signIn() {
        guard !auth.isBusy, !email.isEmpty, !password.isEmpty else { return }
        focus = nil
        let submittedPassword = password
        password = ""
        Task { await connection.signIn(email: email, password: submittedPassword) }
    }
}

struct AccountScreen<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "house.lodge.fill").font(.largeTitle).foregroundStyle(Palette.action)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(title: "HOUSEKEEPING")
                    Text(title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(subtitle).foregroundStyle(Palette.secondary)
                }
                content
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(Palette.ink).background(Palette.background)
    }
}

extension View {
    func accountField() -> some View {
        padding(16).frame(minHeight: 52).background(Palette.surface, in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border) }
    }
}

extension AuthenticationFailure {
    var message: String {
        switch self {
        case .invalidCredentials: "We couldn’t sign in. Check your email and password."
        case .emailUnverified: "Please verify your email before signing in."
        case .sessionExpired: "Your session has ended. Please sign in again."
        case .noHousehold: "Your account hasn’t been connected to a household yet."
        case .protectedStorage: "We couldn’t access protected storage. Unlock this iPhone and try again."
        case .unavailable: "We couldn’t connect. Check your connection and try again."
        }
    }
}

#if DEBUG
    #Preview("Sign in") {
        @Previewable @State var connection = AppConnection(
            auth: PreviewAuthenticationService(), recovery: PreviewRecoveryService())
        SignInView(connection: connection).tint(Palette.action)
    }
#endif
