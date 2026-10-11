import Foundation
import Testing

@testable import HouseKeeping

struct LocalDraftStoreTests {
    @Test func draftSurvivesStoreReconstructionIncludingPendingSave() async throws {
        let root = try temporaryRoot()
        defer { cleanup(root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let url = URL(string: "https://offline.invalid")!
        let first = LocalDraftStore(projectURL: url, owner: owner, rootDirectory: root)
        var draft = TextDraft(
            owner: owner,
            fields: .init(name: "Kettle", description: "Unsubmitted text", quantity: 0, restockLimit: 2))
        draft.phase = .submitting
        try await first.save(draft)
        let restored = LocalDraftStore(projectURL: url, owner: owner, rootDirectory: root)
        #expect(try await restored.load() == draft)
        try await restored.clear()
        #expect(try await first.load() == nil)
        try await restored.clear()
    }

    @Test func differentAccountsHouseholdsAndProjectsCannotLoadEachOthersDraft() async throws {
        let root = try temporaryRoot()
        defer { cleanup(root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let url = URL(string: "https://offline.invalid")!
        let first = LocalDraftStore(projectURL: url, owner: owner, rootDirectory: root)
        let draft = TextDraft(owner: owner, fields: .init(name: "Private draft"))
        try await first.save(draft)
        for other in [
            DraftOwner(accountID: UUID(), householdID: owner.householdID),
            DraftOwner(accountID: owner.accountID, householdID: UUID()),
        ] {
            let store = LocalDraftStore(projectURL: url, owner: other, rootDirectory: root)
            #expect(try await store.load() == nil)
            await #expect(throws: DraftStorageFailure.invalidData) { try await store.save(draft) }
            try await store.clear()
        }
        let otherProject = LocalDraftStore(
            projectURL: URL(string: "https://other.invalid")!, owner: owner, rootDirectory: root)
        #expect(try await otherProject.load() == nil)
        #expect(try await first.load() == draft)
    }

    @Test func corruptOrOversizedDraftIsReportedWithoutOverwritingIt() async throws {
        let root = try temporaryRoot()
        defer { cleanup(root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let store = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!, owner: owner, rootDirectory: root)
        try await store.save(TextDraft(owner: owner, fields: .init(name: "")))
        let file = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file)
        await #expect(throws: DraftStorageFailure.invalidData) { try await store.load() }
        #expect(try Data(contentsOf: file) == corrupt)
        await #expect(throws: DraftStorageFailure.tooLarge) {
            try await store.save(TextDraft(owner: owner, fields: .init(name: String(repeating: "a", count: 70_000))))
        }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func draftFileUsesPrivatePermissionsAndRequestsCompleteProtection() async throws {
        let root = try temporaryRoot()
        defer { cleanup(root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let store = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!, owner: owner, rootDirectory: root)
        try await store.save(TextDraft(owner: owner, fields: .init(name: "Kettle")))
        let file = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(LocalDraftStore.writingOptions.contains(.atomic))
        #expect(LocalDraftStore.writingOptions.contains(.completeFileProtection))
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func imageDraftSurvivesRelaunchAndIsPartitionedByAccountAndProject() async throws {
        let root = try temporaryRoot()
        defer { cleanup(root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let otherOwner = DraftOwner(accountID: UUID(), householdID: owner.householdID)
        let url = URL(string: "https://offline.invalid")!
        let prepared = try await PhotoPreparation().prepare(
            photoFixtureJPEG(width: 48, height: 32, metadata: true))
        var draft = ImageDraft(id: UUID(), owner: owner, prepared: prepared)
        let photoID = UUID()
        draft.upload = PhotoUploadState(
            requestId: UUID(),
            reservation: .init(
                photoId: photoID,
                objectKey: PhotoReservation.objectKey(
                    householdID: owner.householdID, uploaderID: owner.accountID, photoID: photoID),
                expiresAt: Date().addingTimeInterval(3600)), isReady: true)
        let first = LocalDraftStore(projectURL: url, owner: owner, rootDirectory: root)
        try await first.saveImageDraft(draft)

        let restored = LocalDraftStore(projectURL: url, owner: owner, rootDirectory: root)
        #expect(try await restored.loadImageDraft() == draft)
        #expect(
            try await LocalDraftStore(
                projectURL: url, owner: otherOwner, rootDirectory: root
            ).loadImageDraft() == nil)
        #expect(
            try await LocalDraftStore(
                projectURL: URL(string: "https://other.invalid")!, owner: owner, rootDirectory: root
            ).loadImageDraft() == nil)
    }

    @Test func explicitImageDiscardPreservesTextAndAccountClearRemovesBoth() async throws {
        let root = try temporaryRoot()
        defer { cleanup(root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let store = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!, owner: owner, rootDirectory: root)
        let otherOwner = DraftOwner(accountID: UUID(), householdID: owner.householdID)
        let otherStore = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!, owner: otherOwner, rootDirectory: root)
        let text = TextDraft(owner: owner, fields: .init(name: "Kettle"))
        let prepared = try await PhotoPreparation().prepare(photoFixtureJPEG(width: 24, height: 16))
        try await store.save(text)
        try await store.saveImageDraft(ImageDraft(id: UUID(), owner: owner, prepared: prepared))
        let otherDraft = ImageDraft(id: UUID(), owner: otherOwner, prepared: prepared)
        try await otherStore.saveImageDraft(otherDraft)

        try await store.clearImageDraft()
        #expect(try await store.load() == text)
        #expect(try await store.loadImageDraft() == nil)
        try await store.saveImageDraft(ImageDraft(id: UUID(), owner: owner, prepared: prepared))
        try await store.clear()
        #expect(try await store.load() == nil)
        #expect(try await store.loadImageDraft() == nil)
        #expect(try await otherStore.loadImageDraft() == otherDraft)
    }

    @Test func corruptImageDraftIsRejectedAndProtectedFileIsExcludedFromBackup() async throws {
        let root = try temporaryRoot()
        defer { cleanup(root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let store = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!, owner: owner, rootDirectory: root)
        let prepared = try await PhotoPreparation().prepare(photoFixtureJPEG(width: 24, height: 16))
        try await store.saveImageDraft(ImageDraft(id: UUID(), owner: owner, prepared: prepared))
        let file = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "photo" })
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        try Data("corrupt image draft".utf8).write(to: file, options: .atomic)
        await #expect(throws: DraftStorageFailure.invalidData) { try await store.loadImageDraft() }
    }

    @Test(.enabled(if: isPhysicalDevice))
    func physicalDeviceReportsCompleteFileProtection() async throws {
        let root = try temporaryRoot()
        defer { cleanup(root) }
        let owner = DraftOwner(accountID: UUID(), householdID: UUID())
        let store = LocalDraftStore(
            projectURL: URL(string: "https://offline.invalid")!, owner: owner, rootDirectory: root)
        try await store.save(TextDraft(owner: owner, fields: .init(name: "Synthetic protection check")))
        let file = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue)
    }

    private static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
            false  // Simulator does not expose the file-protection attribute in the tested runtime.
        #else
            true
        #endif
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "housekeeping-draft-test-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) } catch {
            Issue.record("Synthetic draft test directory cleanup failed")
        }
    }
}
