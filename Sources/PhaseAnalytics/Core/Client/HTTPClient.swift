import Foundation
import Gzip

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

internal struct HTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
    let retryAfter: TimeInterval?
}

internal struct HTTPFailure: Error, Sendable {
    let error: PhaseError
    let statusCode: Int?
    let retryAfter: TimeInterval?
    let isRetryable: Bool
    let isCancelled: Bool

    static func transport(_ error: Error) -> HTTPFailure {
        let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        return HTTPFailure(
            error: .networkError(error.localizedDescription),
            statusCode: nil,
            retryAfter: nil,
            isRetryable: true,
            isCancelled: isCancelled
        )
    }

    static func status(_ response: HTTPResponse, message: String) -> HTTPFailure {
        let httpError = HTTPError(statusCode: response.statusCode, message: message)
        return HTTPFailure(
            error: .httpError(statusCode: response.statusCode, message: message),
            statusCode: response.statusCode,
            retryAfter: response.retryAfter,
            isRetryable: httpError.isRetryable(),
            isCancelled: false
        )
    }

    static let encoding = HTTPFailure(
        error: .encodingError, statusCode: nil, retryAfter: nil, isRetryable: false, isCancelled: false)
}

/// Single-attempt transport for `/sdk/batch`. Retries are owned by `BatchSender`, so a request
/// never outlives the flush that issued it and retries never overlap.
internal final class HTTPClient: Sendable {
    private let apiKey: String
    private let baseURL: String
    private let debugData: Bool
    private let session: URLSession

    private static let compressionThresholdBytes = 1024
    private static let requestTimeoutSeconds: TimeInterval = 15
    private static let resourceTimeoutSeconds: TimeInterval = 30
    private static let maxRetryAfterSeconds: TimeInterval = 600
    private static let maxErrorLength = 500

    init(apiKey: String, baseURL: String = "https://api.phase.sh", debugData: Bool = false) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.debugData = debugData

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        config.timeoutIntervalForResource = Self.resourceTimeoutSeconds
        self.session = URLSession(configuration: config)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.userInfo[.phaseWireFormat] = true
        return encoder
    }

    /// Returns any HTTP response as success so the caller can apply per-item results (200/207/4xx).
    func sendBatch(_ payload: BatchRequest) async -> Result<HTTPResponse, HTTPFailure> {
        await post(endpoint: "/sdk/batch", body: payload, compressible: true)
    }

    func decodeBatchResponse(_ data: Data) -> BatchResponse? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(BatchResponse.self, from: data)
    }

    func errorMessage(_ response: HTTPResponse) -> String {
        let text = String(data: response.data, encoding: .utf8) ?? "Unknown error"
        if text.count > Self.maxErrorLength {
            return String(text.prefix(Self.maxErrorLength)) + "... (truncated)"
        }
        return text
    }

    private func post<T: Encodable & Sendable>(
        endpoint: String,
        body: T,
        compressible: Bool
    ) async -> Result<HTTPResponse, HTTPFailure> {
        var bodyData: Data
        do {
            bodyData = try makeEncoder().encode(body)
        } catch {
            logger.error("Failed to encode \(endpoint) request body", error)
            return .failure(.encoding)
        }

        guard let url = URL(string: baseURL + endpoint) else {
            return .failure(
                HTTPFailure(
                    error: .networkError("Invalid URL: \(baseURL + endpoint)"),
                    statusCode: nil,
                    retryAfter: nil,
                    isRetryable: false,
                    isCancelled: false
                ))
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if debugData {
            urlRequest.setValue("1", forHTTPHeaderField: "x-phase-debug-data")
        }

        if compressible, bodyData.count >= Self.compressionThresholdBytes, let compressed = try? bodyData.gzipped() {
            bodyData = compressed
            urlRequest.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        urlRequest.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.transport(URLError(.badServerResponse)))
            }
            return .success(
                HTTPResponse(
                    statusCode: httpResponse.statusCode,
                    data: data,
                    retryAfter: Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                ))
        } catch {
            return .failure(.transport(error))
        }
    }

    /// Retry-After is either delta-seconds or an HTTP-date (RFC 9110 §10.2.3).
    private static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }

        let seconds: TimeInterval?
        if let delta = TimeInterval(value) {
            seconds = delta
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            seconds = formatter.date(from: value).map { $0.timeIntervalSinceNow }
        }

        guard let seconds, seconds.isFinite else { return nil }
        return min(max(seconds, 0), maxRetryAfterSeconds)
    }
}
