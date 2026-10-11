import Foundation

/// Public connection settings only. This type never represents an administrator credential.
struct AppConfiguration: Sendable {
    enum Failure: Error, Equatable { case missing, invalidURL, invalidKey }

    let url: URL
    let publishableKey: String

    init(values: [String: String], allowLocalHTTP: Bool) throws {
        let address = values["HK_SUPABASE_URL", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let key = values["HK_SUPABASE_PUBLISHABLE_KEY", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !key.isEmpty else { throw Failure.missing }
        guard let parts = URLComponents(string: address), let url = parts.url,
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/",
            parts.scheme == "https"
                || (allowLocalHTTP && parts.scheme == "http" && host == "127.0.0.1" && parts.port == 55321)
        else { throw Failure.invalidURL }
        guard Self.isPublicKey(key) else { throw Failure.invalidKey }
        self.url = url
        publishableKey = key
    }

    static func bundled() -> Result<Self, Failure> {
        #if DEBUG
            let allowLocalHTTP = true
        #else
            let allowLocalHTTP = false
        #endif
        do {
            let values = (Bundle.main.infoDictionary ?? [:]).compactMapValues { $0 as? String }
            return .success(try Self(values: values, allowLocalHTTP: allowLocalHTTP))
        } catch let error as Failure {
            return .failure(error)
        } catch {
            return .failure(.missing)
        }
    }

    private static func isPublicKey(_ key: String) -> Bool {
        if key.range(of: #"\Asb_publishable_[A-Za-z0-9_-]{20,}\z"#, options: .regularExpression) != nil { return true }
        let pieces = key.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
            pieces.allSatisfy({ $0.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil })
        else { return false }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
            of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        // This checks key type, not authenticity. Supabase verifies the credential.
        return claims["role"] as? String == "anon"
    }
}
