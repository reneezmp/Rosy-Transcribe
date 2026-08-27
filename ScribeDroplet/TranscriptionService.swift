import Foundation

/// The languages offered in the picker. `auto` omits `language_code` entirely
/// and lets the model detect it.
enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto
    case portuguese
    case english
    case spanish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .portuguese: return "Portuguese"
        case .english: return "English"
        case .spanish: return "Spanish"
        }
    }

    /// ISO 639-3, as the API expects. Nil means: do not send the parameter.
    var languageCode: String? {
        switch self {
        case .auto: return nil
        case .portuguese: return "por"
        case .english: return "eng"
        case .spanish: return "spa"
        }
    }
}

/// Every failure this app can produce, each with a message a human can act on.
enum TranscriptionError: LocalizedError {
    case missingAPIKey
    case fileMissing(URL)
    case fileUnreadable(URL, underlying: Error)
    case fileEmpty(URL)
    case fileTooLarge(bytes: Int64, limit: Int64)
    case unauthorized(String?)
    case forbidden(String?)
    case quotaExhausted(String?)
    case rateLimited(String?)
    case payloadTooLarge(String?)
    case unsupportedMedia(String?)
    case invalidRequest(status: Int, message: String?)
    case serverError(status: Int, message: String?)
    case timedOut
    case networkUnreachable(String)
    case cancelled
    case network(String)
    case notHTTP
    case undecodableResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key. Paste your ElevenLabs key into the field at the top of the window."
        case .fileMissing(let url):
            return "The file is no longer at \(url.path). It may have been moved or renamed since you dropped it."
        case .fileUnreadable(let url, let underlying):
            return "Could not read \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .fileEmpty(let url):
            return "\(url.lastPathComponent) is empty — there is nothing to transcribe."
        case .fileTooLarge(let bytes, let limit):
            return "That file is \(Self.formatBytes(bytes)). The API accepts at most \(Self.formatBytes(limit)) per upload."
        case .unauthorized(let detail):
            return Self.compose("The API rejected the key (401). Check it for a typo or a stray space.", detail)
        case .forbidden(let detail):
            return Self.compose("The key was accepted but is not allowed to use speech-to-text (403).", detail)
        case .quotaExhausted(let detail):
            return Self.compose("Your ElevenLabs quota is exhausted (402). Top up the account and try again.", detail)
        case .rateLimited(let detail):
            return Self.compose("Rate limited or out of quota (429). Wait a moment and try again.", detail)
        case .payloadTooLarge(let detail):
            return Self.compose("The server rejected the upload as too large (413).", detail)
        case .unsupportedMedia(let detail):
            return Self.compose("The server could not decode that audio file (415). Try converting it to MP3 or WAV.", detail)
        case .invalidRequest(let status, let detail):
            return Self.compose("The server rejected the request (\(status)).", detail)
        case .serverError(let status, let detail):
            return Self.compose("The server returned an unexpected error (\(status)).", detail)
        case .timedOut:
            return "The request timed out. Large files on a slow connection can take a while — it is worth trying again."
        case .networkUnreachable(let detail):
            return "Cannot reach api.elevenlabs.io. Check the network connection. (\(detail))"
        case .cancelled:
            return "The transcription was cancelled."
        case .network(let detail):
            return "Network error: \(detail)"
        case .notHTTP:
            return "The server sent a response that was not HTTP. This should not happen."
        case .undecodableResponse(let detail):
            return "The transcription came back in a shape this app did not expect: \(detail)"
        }
    }

    /// Appends whatever the API said, when it said anything. A status code on
    /// its own is rarely enough to act on.
    private static func compose(_ message: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return message }
        return "\(message)\n\nThe server said: \(detail)"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct TranscriptionRequest {
    let fileURL: URL
    let apiKey: String
    /// Nil auto-detects.
    let languageCode: String?
    /// Terms to bias recognition. Empty means: do not send the parameter.
    let keyterms: [String]

    init(fileURL: URL, apiKey: String, languageCode: String?, keyterms: [String] = []) {
        self.fileURL = fileURL
        self.apiKey = apiKey
        self.languageCode = languageCode
        self.keyterms = keyterms
    }
}

/// The one place that talks to ElevenLabs.
struct TranscriptionService {

    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    static let modelID = "scribe_v2"

    /// The documented ceiling for a direct upload. Checked before the upload
    /// starts, so an oversized file fails instantly instead of after twenty
    /// minutes of pushing bytes at a server that will refuse them.
    static let maxUploadBytes: Int64 = 5 * 1024 * 1024 * 1024

    private let session: URLSession
    private let boundaryProvider: () -> String

    init(session: URLSession = TranscriptionService.makeSession(),
         boundaryProvider: @escaping () -> String = MultipartBuilder.randomBoundary) {
        self.session = session
        self.boundaryProvider = boundaryProvider
    }

    /// The default timeouts kill exactly the uploads that matter most: a
    /// forty-minute meeting, from a 2017 laptop, on ordinary wifi, followed by
    /// server-side processing.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300     // 5 minutes of no progress
        configuration.timeoutIntervalForResource = 3600   // 1 hour, whole transfer
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration)
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        let apiKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranscriptionError.missingAPIKey }

        let fileData = try Self.readFile(at: request.fileURL)

        let builder = MultipartBuilder(boundary: boundaryProvider())
        let body = builder.body(fields: Self.formFields(languageCode: request.languageCode,
                                                        keyterms: request.keyterms),
                                fileFieldName: "file",
                                fileName: request.fileURL.lastPathComponent,
                                fileMIMEType: MultipartBuilder.mimeType(forPathExtension: request.fileURL.pathExtension),
                                fileData: fileData)

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue(builder.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, from: body)
        } catch let error as URLError {
            throw Self.translate(error)
        }

        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.notHTTP }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(forStatus: http.statusCode, body: data)
        }

        do {
            return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        } catch {
            throw TranscriptionError.undecodableResponse(error.localizedDescription)
        }
    }

    /// The form fields for one request, in the order they go on the wire.
    ///
    /// Split out from `transcribe` so the exact shape of the request can be
    /// asserted in tests without touching the network — this is where the
    /// keyterms format went wrong once already.
    static func formFields(languageCode: String?, keyterms: [String]) -> [MultipartField] {
        var fields = [
            MultipartField("model_id", modelID),
            MultipartField("diarize", "true"),
            MultipartField("timestamps_granularity", "word"),
        ]
        // Omitted entirely for auto-detect: sending an empty string is not the
        // same thing as sending nothing.
        if let languageCode {
            fields.append(MultipartField("language_code", languageCode))
        }
        // An array parameter over multipart is the same name repeated, one
        // part per term. Sending them as a JSON array in a single part made
        // the server measure the whole array as one keyword and reject it
        // with "All keywords must be less than 50 characters".
        for term in keyterms {
            fields.append(MultipartField("keyterms", term))
        }
        return fields
    }

    // MARK: - Reading the file

    private static func readFile(at url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.fileMissing(url)
        }

        let size: Int64
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            size = Int64(values.fileSize ?? 0)
        } catch {
            throw TranscriptionError.fileUnreadable(url, underlying: error)
        }

        guard size > 0 else { throw TranscriptionError.fileEmpty(url) }
        guard size <= maxUploadBytes else {
            throw TranscriptionError.fileTooLarge(bytes: size, limit: maxUploadBytes)
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw TranscriptionError.fileUnreadable(url, underlying: error)
        }
    }

    // MARK: - Errors

    static func translate(_ error: URLError) -> TranscriptionError {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed:
            return .networkUnreachable(error.localizedDescription)
        default:
            return .network(error.localizedDescription)
        }
    }

    static func error(forStatus status: Int, body: Data) -> TranscriptionError {
        let detail = errorMessage(from: body)
        switch status {
        case 401: return .unauthorized(detail)
        case 402: return .quotaExhausted(detail)
        case 403: return .forbidden(detail)
        case 413: return .payloadTooLarge(detail)
        case 415: return .unsupportedMedia(detail)
        case 429: return .rateLimited(detail)
        case 400, 422: return .invalidRequest(status: status, message: detail)
        default:
            if (400..<500).contains(status) {
                return .invalidRequest(status: status, message: detail)
            }
            return .serverError(status: status, message: detail)
        }
    }

    /// ElevenLabs puts errors under `detail`, which is sometimes a string,
    /// sometimes an object with `message`, and sometimes an array of
    /// validation objects. Rather than model all three, dig for the most
    /// human-readable string available and fall back to the raw body.
    static func errorMessage(from body: Data) -> String? {
        guard !body.isEmpty else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: body) {
            if let message = extractMessage(from: json) {
                return message
            }
        }

        guard let raw = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.count > 500 ? String(raw.prefix(500)) + "…" : raw
    }

    private static func extractMessage(from json: Any) -> String? {
        if let string = json as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dictionary = json as? [String: Any] {
            for key in ["message", "detail", "error", "msg"] {
                if let value = dictionary[key], let message = extractMessage(from: value) {
                    return message
                }
            }
            return nil
        }
        if let array = json as? [Any] {
            let messages = array.compactMap(extractMessage(from:))
            return messages.isEmpty ? nil : messages.joined(separator: "; ")
        }
        return nil
    }
}
