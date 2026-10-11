import Foundation

enum RecognitionSource: Equatable, Sendable {
    case provider
    case sample
}

enum UnrecognizedReason: String, Codable, Equatable, Sendable {
    case unclearImage = "UNCLEAR_IMAGE"
    case multipleProducts = "MULTIPLE_PRODUCTS"
    case noProduct = "NO_PRODUCT"
}

struct ProductSuggestion: Codable, Equatable, Sendable {
    let name: String
    let description: String?
    let brand: String?
    let model: String?

    var fields: ItemFields {
        ItemFields(name: name, description: description, brand: brand, model: model)
    }
}

enum RecognitionResult: Equatable, Sendable {
    case suggested(ProductSuggestion)
    case unrecognized(UnrecognizedReason)
}

enum RecognitionFailure: Error, Equatable, Sendable {
    case validation
    case unauthenticated
    case forbidden
    case notFound
    case quotaExceeded
    case inProgress
    case retryRequired
    case providerRefusal
    case invalidResponse
    case unavailable
}

enum RecognitionFlowState: Equatable, Sendable {
    case idle
    case preparing(RecognitionSource)
    case recognizing(RecognitionSource)
    case suggested(RecognitionSource)
    case unrecognized(RecognitionSource, UnrecognizedReason)
    case failed(RecognitionFailure)
    case stale
    case manual

    var isWorking: Bool {
        if case .preparing = self { return true }
        if case .recognizing = self { return true }
        return false
    }
}

@MainActor
protocol RecognitionClient: Sendable {
    var owner: DraftOwner { get }
    var source: RecognitionSource { get }
    func recognize(photoID: UUID, requestID: UUID) async throws -> RecognitionResult
}

/// Recreate after any account transition. The client never receives image bytes or administrator credentials.
@MainActor
final class SupabaseRecognitionClient: RecognitionClient {
    let owner: DraftOwner
    let source = RecognitionSource.provider
    private let auth: SupabaseAuthService
    private let generation: UUID

    init(auth: SupabaseAuthService, owner: DraftOwner) {
        self.auth = auth
        self.owner = owner
        generation = auth.inventoryGeneration
    }

    func recognize(photoID: UUID, requestID: UUID) async throws -> RecognitionResult {
        let body: Data
        do {
            body = try JSONEncoder().encode(Input(photoId: photoID, requestId: requestID))
        } catch {
            throw RecognitionFailure.validation
        }
        let response: (status: Int, data: Data)
        do {
            response = try await auth.recognitionRequest(
                body: body, accountID: owner.accountID, generation: generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as RecognitionFailure {
            throw failure
        } catch let failure as PhotoFailure {
            throw failure == .invalidResponse ? RecognitionFailure.invalidResponse : .unavailable
        } catch let failure as AuthenticationFailure {
            switch failure {
            case .sessionExpired, .invalidCredentials, .emailUnverified:
                throw RecognitionFailure.unauthenticated
            default: throw RecognitionFailure.unavailable
            }
        } catch { throw RecognitionFailure.unavailable }

        guard response.status == 200 else {
            throw Self.failure(status: response.status, data: response.data)
        }
        let decoded: Output
        do {
            decoded = try JSONDecoder().decode(Output.self, from: response.data)
        } catch {
            throw RecognitionFailure.invalidResponse
        }
        guard decoded.photoId == photoID else { throw RecognitionFailure.invalidResponse }
        switch decoded.status {
        case "SUGGESTED":
            guard let suggestion = decoded.suggestion, decoded.reason == nil else {
                throw RecognitionFailure.invalidResponse
            }
            do {
                try suggestion.fields.validate()
            } catch {
                throw RecognitionFailure.invalidResponse
            }
            return .suggested(suggestion)
        case "UNRECOGNIZED":
            guard decoded.suggestion == nil, let reason = decoded.reason else {
                throw RecognitionFailure.invalidResponse
            }
            return .unrecognized(reason)
        default: throw RecognitionFailure.invalidResponse
        }
    }

    private static func failure(status: Int, data: Data) -> RecognitionFailure {
        let code = (try? JSONDecoder().decode(FailureEnvelope.self, from: data))?.error.code
        switch status {
        case 401: return .unauthenticated
        case 403: return .forbidden
        case 404: return .notFound
        case 409:
            if code == "RECOGNITION_IN_PROGRESS" { return .inProgress }
            return code == "RECOGNITION_RETRY_REQUIRED" ? .retryRequired : .validation
        case 422: return .validation
        case 429: return .quotaExceeded
        case 502:
            return code == "PROVIDER_REFUSAL" ? .providerRefusal : .invalidResponse
        case 504: return .retryRequired
        case 503:
            return code == "PROVIDER_UNAVAILABLE" ? .retryRequired : .unavailable
        default: return .unavailable
        }
    }

    private struct Input: Encodable {
        let photoId: UUID
        let requestId: UUID
    }
    private struct Output: Decodable {
        let status: String
        let analysisId: UUID
        let photoId: UUID
        let suggestion: ProductSuggestion?
        let reason: UnrecognizedReason?
    }
    private struct FailureEnvelope: Decodable { let error: Failure }
    private struct Failure: Decodable { let code: String }
}

#if DEBUG
    @MainActor
    final class PreviewRecognitionClient: RecognitionClient {
        enum Behavior { case suggested, unrecognized, timeout }
        let owner: DraftOwner
        let source = RecognitionSource.sample
        private let behavior: Behavior

        init(owner: DraftOwner, behavior: Behavior = .suggested) {
            self.owner = owner
            self.behavior = behavior
        }

        func recognize(photoID: UUID, requestID: UUID) async throws -> RecognitionResult {
            try await Task.sleep(for: .milliseconds(250))
            switch behavior {
            case .suggested:
                return .suggested(
                    ProductSuggestion(
                        name: "Sample recognized kettle",
                        description: "Offline preview suggestion",
                        brand: nil,
                        model: nil))
            case .unrecognized: return .unrecognized(.multipleProducts)
            case .timeout: throw RecognitionFailure.retryRequired
            }
        }
    }
#endif
