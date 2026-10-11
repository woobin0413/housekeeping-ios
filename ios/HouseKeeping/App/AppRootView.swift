import SwiftUI

struct AppRootView: View {
    var isPreview = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: AppConnection?
    @State private var configurationFailure: AppConfiguration.Failure?
    @State private var loaded = false
    @State private var showingDemo = false
    @State private var demo = DemoInventory()
    @State private var offlineAuthenticationPreview = false

    var body: some View {
        Group {
            if showingDemo {
                InventoryView(store: demo)
                    .safeAreaInset(edge: .top) {
                        HStack {
                            Text("OFFLINE DEMO").font(.caption.weight(.semibold))
                            Spacer()
                            Button("Exit demo") {
                                showingDemo = false
                                demo = DemoInventory()
                            }.frame(minHeight: 44)
                        }.padding(.horizontal, 24).background(Palette.sage)
                    }
            } else if let connection {
                VStack(spacing: 0) {
                    if offlineAuthenticationPreview {
                        Text("OFFLINE AUTH PREVIEW · NO NETWORK")
                            .font(.caption).padding(8).frame(maxWidth: .infinity).background(Palette.sage)
                    }
                    AuthenticationGate(connection: connection)
                }
            } else if loaded {
                AccountScreen(title: "Welcome home.", subtitle: "Your private household inventory starts here.") {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(
                            configurationFailure == .missing
                                ? "Supabase isn’t configured yet." : "The Supabase configuration isn’t valid."
                        )
                        .accessibilityIdentifier("configurationStatus")
                        Text(
                            "When setup is ready, add the project URL and public publishable key to the ignored Local.xcconfig file. Never add database passwords or administrator keys to this app."
                        )
                        .font(.callout).foregroundStyle(Palette.secondary)
                        Button("Explore the demo") {
                            demo = DemoInventory()
                            showingDemo = true
                        }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("exploreDemo")
                        Text("The demo uses sample items. Nothing is uploaded or shared.").font(.footnote)
                    }
                }
            } else {
                ProgressView("Opening HouseKeeping…").frame(maxWidth: .infinity, maxHeight: .infinity).background(
                    Palette.background)
            }
        }
        .task { load() }
        .onChange(of: scenePhase) { _, phase in
            guard let connection else { return }
            Task {
                switch phase {
                case .active:
                    await connection.restore()
                case .inactive, .background:
                    _ = await connection.inventory?.drafts.flush()
                @unknown default:
                    break
                }
            }
        }
        .onOpenURL { url in
            load()
            if let connection { Task { await connection.openRecovery(url) } }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if isPreview {
            configurationFailure = .missing
            return
        }
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--demo") {
                showingDemo = true
                configurationFailure = .missing
                return
            }
            if arguments.contains("--preview-auth") || arguments.contains("--preview-recovery")
                || arguments.contains("--preview-inventory")
            {
                offlineAuthenticationPreview = true
                let inventoryFactory: (@MainActor (AccountIdentity, Household) -> InventoryStore)?
                if arguments.contains("--preview-inventory") {
                    let inventoryDatabase = PreviewInventoryDatabase()
                    let draftDatabase = PreviewDraftDatabase()
                    inventoryFactory = { account, household in
                        let owner = DraftOwner(accountID: account.id, householdID: household.householdId)
                        let recognitionBehavior: PreviewRecognitionClient.Behavior =
                            arguments.contains("--preview-recognition-timeout") ? .timeout : .suggested
                        return InventoryStore(
                            repository: PreviewInventoryRepository(
                                householdID: household.householdId, database: inventoryDatabase),
                            draftStorage: PreviewDraftStorage(owner: owner, database: draftDatabase),
                            photoService: PreviewPhotoService(owner: owner, database: inventoryDatabase),
                            recognitionClient: PreviewRecognitionClient(
                                owner: owner, behavior: recognitionBehavior))
                    }
                } else {
                    inventoryFactory = nil
                }
                connection = AppConnection(
                    auth: PreviewAuthenticationService(),
                    recovery: PreviewRecoveryService(
                        status: arguments.contains("--preview-recovery")
                            ? .passwordEntry(email: "person@example.invalid") : nil),
                    makeInventory: inventoryFactory)
                return
            }
            if arguments.contains("--unconfigured")
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            {
                configurationFailure = .missing
                return
            }
        #endif
        switch AppConfiguration.bundled() {
        case .success(let config):
            let bundleID = Bundle.main.bundleIdentifier ?? "com.housekeeping.designpreview"
            let auth = SupabaseAuthService(configuration: config, bundleID: bundleID)
            connection = AppConnection(
                auth: auth,
                recovery: SupabaseRecoveryService(configuration: config, bundleID: bundleID),
                makeInventory: { account, household in
                    let owner = DraftOwner(accountID: account.id, householdID: household.householdId)
                    return InventoryStore(
                        repository: SupabaseInventoryRepository(
                            auth: auth, accountID: account.id, householdID: household.householdId),
                        draftStorage: LocalDraftStore(
                            projectURL: config.url, owner: owner),
                        photoService: SupabasePhotoService(
                            auth: auth, owner: owner))
                })
        case .failure(let failure): configurationFailure = failure
        }
    }
}

private struct AuthenticationGate: View {
    @Environment(\.scenePhase) private var scenePhase
    let connection: AppConnection

    var body: some View {
        Group {
            if connection.isRestoring {
                ProgressView("Checking your account…").frame(maxWidth: .infinity, maxHeight: .infinity).background(
                    Palette.background)
            } else if connection.recovery.state != .inactive {
                PasswordRecoveryView(recovery: connection.recovery)
            } else if connection.auth.state == .signedOut {
                SignInView(connection: connection)
            } else if case .ready = connection.auth.state, let inventory = connection.inventory,
                inventory.accessFailure == nil, !connection.draftTransitionFailed
            {
                ConnectedInventoryView(store: inventory, connection: connection)
                    .id(ObjectIdentifier(inventory))
            } else {
                AccountView(connection: connection)
            }
        }
        .task { await connection.restore() }
        .safeAreaInset(edge: .top) {
            if connection.callbackRequiresSignOut {
                Text("Sign out, then open the recovery link again.").font(.callout).padding().background(Palette.sage)
            }
        }
        .overlay {
            if scenePhase != .active {
                Palette.background.ignoresSafeArea().overlay {
                    Image(systemName: "lock.fill").font(.largeTitle).accessibilityLabel("HouseKeeping locked")
                }
            }
        }
    }
}

#Preview("Setup") { AppRootView(isPreview: true).tint(Palette.action) }
