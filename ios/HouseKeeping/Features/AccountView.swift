import SwiftUI

struct AccountView: View {
    let connection: AppConnection
    private var auth: AuthSession { connection.auth }
    @State private var confirmsDiscard = false

    var body: some View {
        AccountScreen(title: "Your shared home", subtitle: "A private space for the two of you.") {
            VStack(alignment: .leading, spacing: 20) {
                switch auth.state {
                case .ready(let account, let home):
                    Text(home.name).font(.title2).accessibilityIdentifier("householdName")
                    Text(account.email).accessibilityIdentifier("accountEmail")
                    Text(
                        connection.inventory == nil
                            ? "You’re connected. Inventory is unavailable in this authentication-only preview."
                            : "Your saved purchases are shared with your household. Unsubmitted drafts stay on this iPhone."
                    )
                    .foregroundStyle(Palette.secondary)
                case .needsHousehold(let account):
                    Text(account.email)
                    Text(
                        "Your account isn’t linked to a household yet. Ask the person setting up HouseKeeping to connect both accounts."
                    )
                    .accessibilityIdentifier("noHousehold")
                case .blocked(let failure): Text(failure.message).accessibilityIdentifier("accountError")
                default: ProgressView("Checking your account…")
                }
                if connection.draftTransitionFailed {
                    Text(
                        "We couldn’t safely preserve or clear your local draft. Unlock this iPhone and retry. Your edits are still retained."
                    )
                    .accessibilityIdentifier("draftTransitionError")
                }
                if let failure = connection.inventory?.accessFailure {
                    Text(failure.message).accessibilityIdentifier("inventoryAccessError")
                }
                Button("Check connection") { Task { await connection.restore() } }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("retryAccount")
                Button("Sign out") {
                    if connection.needsDraftDiscardConfirmation {
                        confirmsDiscard = true
                    } else {
                        Task { await connection.signOut() }
                    }
                }
                .frame(minHeight: 44).accessibilityIdentifier("signOut")
            }
            .disabled(auth.isBusy || connection.isRestoring)
        }
        .alert("Discard your local draft and sign out?", isPresented: $confirmsDiscard) {
            Button("Discard and sign out", role: .destructive) {
                Task { await connection.signOut(confirmedDiscard: true) }
            }
            Button("Keep draft", role: .cancel) {}
        } message: {
            Text(
                "Unsaved text on this iPhone will be removed. A purchase already accepted by the server will remain in the shared inventory."
            )
        }
    }
}
