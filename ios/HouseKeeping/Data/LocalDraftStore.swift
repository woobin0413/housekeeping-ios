import CryptoKit
import Foundation

/// Bounded text and photo files per project/account/household; no credentials or network access.
actor LocalDraftStore: DraftStorage, ImageDraftStorage {
    nonisolated let owner: DraftOwner
    private let fileURL: URL
    private let imageFileURL: URL
    private let directory: URL
    private static let maximumBytes = 64 * 1024
    private static let maximumImageFileBytes = PhotoPreparation.maximumOutputBytes + 4_096
    static let writingOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    init(projectURL: URL, owner: DraftOwner, rootDirectory: URL? = nil) {
        self.owner = owner
        directory =
            rootDirectory
            ?? URL.applicationSupportDirectory.appending(path: "HouseKeeping/Drafts", directoryHint: .isDirectory)
        let digest = SHA256.hash(data: Data(projectURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let partition = "\(digest)-\(owner.accountID)-\(owner.householdID)"
        fileURL = directory.appending(path: "\(partition).json")
        imageFileURL = directory.appending(path: "\(partition).photo")
    }

    func load() throws -> TextDraft? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? Int, size <= Self.maximumBytes
            else { throw DraftStorageFailure.invalidData }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maximumBytes else { throw DraftStorageFailure.tooLarge }
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1, envelope.draft.owner == owner else {
                    throw DraftStorageFailure.invalidData
                }
                try envelope.draft.validateStorage()
                return envelope.draft
            } catch { throw DraftStorageFailure.invalidData }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil } catch {
            throw Self.normalize(error)
        }
    }

    func save(_ draft: TextDraft) throws {
        guard draft.owner == owner else { throw DraftStorageFailure.invalidData }
        do {
            do { try draft.validateStorage() } catch { throw DraftStorageFailure.invalidData }
            let data = try JSONEncoder().encode(Envelope(version: 1, draft: draft))
            guard data.count <= Self.maximumBytes else { throw DraftStorageFailure.tooLarge }
            try prepareDirectory()
            try data.write(to: fileURL, options: Self.writingOptions)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { throw Self.normalize(error) }
    }

    func clear() throws {
        var firstFailure: (any Error)?
        for url in [fileURL, imageFileURL] {
            do { try removeIfPresent(url) } catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw Self.normalize(firstFailure) }
    }

    func loadImageDraft() throws -> ImageDraft? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: imageFileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber
            else { throw DraftStorageFailure.invalidData }
            guard size.intValue <= Self.maximumImageFileBytes else {
                throw DraftStorageFailure.tooLarge
            }
            let data = try Data(contentsOf: imageFileURL)
            guard data.count <= Self.maximumImageFileBytes else {
                throw DraftStorageFailure.tooLarge
            }
            do {
                let envelope = try PropertyListDecoder().decode(ImageEnvelope.self, from: data)
                guard envelope.version == 1, envelope.draft.owner == owner else {
                    throw DraftStorageFailure.invalidData
                }
                try envelope.draft.validateStorage()
                return envelope.draft
            } catch { throw DraftStorageFailure.invalidData }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw Self.normalize(error)
        }
    }

    func saveImageDraft(_ draft: ImageDraft) throws {
        guard draft.owner == owner else { throw DraftStorageFailure.invalidData }
        do {
            do { try draft.validateStorage() } catch { throw DraftStorageFailure.invalidData }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(ImageEnvelope(version: 1, draft: draft))
            guard data.count <= Self.maximumImageFileBytes else { throw DraftStorageFailure.tooLarge }
            try prepareDirectory()
            try data.write(to: imageFileURL, options: Self.writingOptions)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageFileURL.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = imageFileURL
            try protectedURL.setResourceValues(values)
        } catch { throw Self.normalize(error) }
    }

    func clearImageDraft() throws {
        do { try removeIfPresent(imageFileURL) } catch { throw Self.normalize(error) }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(values)
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch let error as CocoaError
            where error.code == .fileNoSuchFile
        { return }
    }

    private struct ImageEnvelope: Codable {
        let version: Int
        let draft: ImageDraft
    }

    private static func normalize(_ error: any Error) -> DraftStorageFailure {
        error as? DraftStorageFailure ?? .unavailable
    }

    private struct Envelope: Codable {
        let version: Int
        let draft: TextDraft
    }
}
