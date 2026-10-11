import Foundation
import Testing

@testable import HouseKeeping

struct AppConfigurationTests {
    private let key = "sb_publishable_abcdefghijklmnopqrstuvwxyz"

    @Test func missingConfiguration() {
        #expect(throws: AppConfiguration.Failure.missing) { try AppConfiguration(values: [:], allowLocalHTTP: true) }
    }

    @Test func validPublicConfiguration() throws {
        let config = try AppConfiguration(
            values: ["HK_SUPABASE_URL": "https://test.supabase.co", "HK_SUPABASE_PUBLISHABLE_KEY": key],
            allowLocalHTTP: false)
        #expect(config.url.host() == "test.supabase.co")
    }

    @Test(arguments: [
        "http://example.com", "https://user:password@test.supabase.co", "https://test.supabase.co/path",
        "https://test.supabase.co?key=value", "not a URL",
    ])
    func invalidURLs(url: String) {
        #expect(throws: AppConfiguration.Failure.invalidURL) {
            try AppConfiguration(
                values: ["HK_SUPABASE_URL": url, "HK_SUPABASE_PUBLISHABLE_KEY": key], allowLocalHTTP: true)
        }
    }

    @Test func localHTTPOnlyInDebug() throws {
        let values = ["HK_SUPABASE_URL": "http://127.0.0.1:55321", "HK_SUPABASE_PUBLISHABLE_KEY": key]
        #expect(try AppConfiguration(values: values, allowLocalHTTP: true).url.port == 55321)
        #expect(throws: AppConfiguration.Failure.invalidURL) {
            try AppConfiguration(values: values, allowLocalHTTP: false)
        }
    }

    @Test(arguments: ["sb_secret_never-embed-this", "placeholder", "$(HK_SUPABASE_PUBLISHABLE_KEY)"])
    func rejectsNonPublicKeys(key: String) {
        #expect(throws: AppConfiguration.Failure.invalidKey) {
            try AppConfiguration(
                values: ["HK_SUPABASE_URL": "https://test.supabase.co", "HK_SUPABASE_PUBLISHABLE_KEY": key],
                allowLocalHTTP: false)
        }
    }

    @Test func legacyJWTMustBeAnonymous() throws {
        func jwt(role: String) -> String {
            let payload = Data("{\"role\":\"\(role)\"}".utf8).base64EncodedString().replacingOccurrences(
                of: "=", with: "")
            return "e30.\(payload).signature"
        }
        #expect(throws: AppConfiguration.Failure.invalidKey) {
            try AppConfiguration(
                values: [
                    "HK_SUPABASE_URL": "https://test.supabase.co",
                    "HK_SUPABASE_PUBLISHABLE_KEY": jwt(role: "service_role"),
                ], allowLocalHTTP: false)
        }
        _ = try AppConfiguration(
            values: ["HK_SUPABASE_URL": "https://test.supabase.co", "HK_SUPABASE_PUBLISHABLE_KEY": jwt(role: "anon")],
            allowLocalHTTP: false)
    }
}
