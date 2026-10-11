import Foundation
import Testing

@testable import HouseKeeping

struct KeychainSessionStorageTests {
    @Test func roundTripUpdateRemovalAndIsolation() throws {
        let project = try #require(URL(string: "https://test.supabase.co"))
        let bundleID = "com.housekeeping.tests." + UUID().uuidString
        let store = KeychainSessionStorage(projectURL: project, bundleID: bundleID)
        let other = KeychainSessionStorage(projectURL: project, bundleID: bundleID + ".other")
        defer { try? store.remove(key: "session") }
        #expect(try store.retrieve(key: "session") == nil)
        try store.store(key: "session", value: Data("synthetic-session".utf8))
        #expect(try store.retrieve(key: "session") == Data("synthetic-session".utf8))
        #expect(try other.retrieve(key: "session") == nil)
        try store.store(key: "session", value: Data("replacement".utf8))
        #expect(try store.retrieve(key: "session") == Data("replacement".utf8))
        try store.remove(key: "session")
        #expect(try store.retrieve(key: "session") == nil)
        try store.remove(key: "session")
    }

    @Test func projectNamespacesDiffer() throws {
        let first = KeychainSessionStorage(
            projectURL: try #require(URL(string: "https://a.supabase.co")), bundleID: "test")
        let second = KeychainSessionStorage(
            projectURL: try #require(URL(string: "https://b.supabase.co")), bundleID: "test")
        #expect(first.service != second.service)
    }
}
