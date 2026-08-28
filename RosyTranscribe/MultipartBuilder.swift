import Foundation

/// One `form-data` part carrying a plain string.
///
/// A dictionary cannot express an array field, because an array arrives as the
/// *same name repeated* — `keyterms` once per term. That is why fields are an
/// ordered list of these rather than `[String: String]`.
struct MultipartField: Equatable {
    let name: String
    let value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// Hand-assembles a `multipart/form-data` body.
///
/// URLSession has no built-in encoder for this, and the ways to get it wrong
/// all produce the same thing: a bare 400 with no diagnostic. The rules that
/// matter, all enforced below:
///
/// - every line terminator in the envelope is CRLF, never a bare LF
/// - each part opens with `--<boundary>`
/// - the final boundary is `--<boundary>--`
/// - every part carries a `Content-Disposition: form-data; name="..."` line
/// - the file part additionally carries `filename="..."` and `Content-Type`
/// - one blank line separates a part's headers from its content
///
/// The body is built as `Data` rather than `String`, because audio bytes are
/// not UTF-8 and round-tripping them through a String would corrupt them.
struct MultipartBuilder {

    let boundary: String

    /// The boundary is injectable so tests can assert on an exact byte string.
    init(boundary: String = MultipartBuilder.randomBoundary()) {
        self.boundary = boundary
    }

    static func randomBoundary() -> String {
        "RosyTranscribe-\(UUID().uuidString)"
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Encodes string fields plus one file part.
    ///
    /// Fields are emitted in the order given, and a name may appear more than
    /// once — that is how an array-valued parameter is expressed.
    func body(fields: [MultipartField],
              fileFieldName: String,
              fileName: String,
              fileMIMEType: String,
              fileData: Data) -> Data {
        var body = Data()

        for field in fields {
            body.append(Self.bytes("--\(boundary)\(Self.crlf)"))
            body.append(Self.bytes("Content-Disposition: form-data; name=\"\(Self.escapeHeaderValue(field.name))\"\(Self.crlf)"))
            body.append(Self.bytes(Self.crlf))
            body.append(Self.bytes(field.value))
            body.append(Self.bytes(Self.crlf))
        }

        body.append(Self.bytes("--\(boundary)\(Self.crlf)"))
        body.append(Self.bytes("Content-Disposition: form-data; name=\"\(Self.escapeHeaderValue(fileFieldName))\"; filename=\"\(Self.escapeHeaderValue(fileName))\"\(Self.crlf)"))
        body.append(Self.bytes("Content-Type: \(fileMIMEType)\(Self.crlf)"))
        body.append(Self.bytes(Self.crlf))
        body.append(fileData)
        body.append(Self.bytes(Self.crlf))

        body.append(Self.bytes("--\(boundary)--\(Self.crlf)"))
        return body
    }

    /// Convenience for the simple case of distinct, single-valued fields.
    /// Emitted in sorted key order, because a deterministic body is far easier
    /// to test and the order is irrelevant to the server.
    func body(fields: [String: String],
              fileFieldName: String,
              fileName: String,
              fileMIMEType: String,
              fileData: Data) -> Data {
        body(fields: fields.keys.sorted().map { MultipartField($0, fields[$0] ?? "") },
             fileFieldName: fileFieldName,
             fileName: fileName,
             fileMIMEType: fileMIMEType,
             fileData: fileData)
    }

    /// Convenience wrapper that reads the file and derives its MIME type.
    ///
    /// `Data(contentsOf:)` holds the whole file in memory. That is fine for the
    /// sizes this app actually sees — a 40-minute meeting is tens of megabytes —
    /// and it keeps the encoder a pure function of its inputs. If memory
    /// pressure ever shows up on the Intel machine, the change is to spool the
    /// envelope to a temp file and use `uploadTask(with:fromFile:)` instead.
    func body(fields: [MultipartField],
              fileFieldName: String,
              fileURL: URL) throws -> Data {
        let fileData = try Data(contentsOf: fileURL)
        return body(fields: fields,
                    fileFieldName: fileFieldName,
                    fileName: fileURL.lastPathComponent,
                    fileMIMEType: Self.mimeType(forPathExtension: fileURL.pathExtension),
                    fileData: fileData)
    }

    // MARK: - Bytes

    static let crlf = "\r\n"

    private static func bytes(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// Quotes and control characters in a header value would break out of the
    /// envelope, so they are removed rather than escaped. Filenames are the
    /// only value here that comes from outside the app.
    private static func escapeHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "'")
    }

    // MARK: - MIME types

    /// A small, explicit table. Deliberately not UTType lookup: this is the
    /// list of things the API accepts, and it should be obvious on the page.
    static let audioPathExtensions: Set<String> = Set(mimeTypesByExtension.keys)

    private static let mimeTypesByExtension: [String: String] = [
        "aac": "audio/aac",
        "aif": "audio/aiff",
        "aiff": "audio/aiff",
        "amr": "audio/amr",
        "caf": "audio/x-caf",
        "flac": "audio/flac",
        "m4a": "audio/mp4",
        "m4b": "audio/mp4",
        "mka": "audio/x-matroska",
        "mkv": "video/x-matroska",
        "mov": "video/quicktime",
        "mp3": "audio/mpeg",
        "mp4": "video/mp4",
        "mpeg": "audio/mpeg",
        "mpga": "audio/mpeg",
        "oga": "audio/ogg",
        "ogg": "audio/ogg",
        "opus": "audio/opus",
        "wav": "audio/wav",
        "webm": "video/webm",
        "wma": "audio/x-ms-wma",
    ]

    static func mimeType(forPathExtension pathExtension: String) -> String {
        mimeTypesByExtension[pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
