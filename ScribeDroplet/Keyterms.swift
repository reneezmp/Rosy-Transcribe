import Foundation

/// The glossary sent to the API to bias recognition toward words it would
/// otherwise mishear — proper nouns, and legal vocabulary like "proferida",
/// which Scribe will otherwise happily hear as the far more common "preferida".
///
/// Pure: parsing and validation are a function from a string to terms, with no
/// UI or networking types, so the limits are testable without the API.
enum Keyterms {

    /// Documented limits, enforced here so a mistake surfaces instantly with a
    /// clear message rather than as a 422 after the upload has finished.
    static let maxCount = 100
    static let maxCharacters = 50
    static let maxWords = 5

    /// Splits on commas and newlines, trims each term, drops blanks, and
    /// removes duplicates while keeping the order they were typed in.
    static func parse(_ raw: String) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !seen.contains(term) else { continue }
            seen.insert(term)
            terms.append(term)
        }
        return terms
    }

    static func validate(_ terms: [String]) throws {
        guard terms.count <= maxCount else {
            throw KeytermsError.tooMany(count: terms.count)
        }
        for term in terms {
            guard term.count <= maxCharacters else {
                throw KeytermsError.termTooLong(term: term)
            }
            guard wordCount(term) <= maxWords else {
                throw KeytermsError.termHasTooManyWords(term: term)
            }
        }
    }

    static func validated(_ raw: String) throws -> [String] {
        let terms = parse(raw)
        try validate(terms)
        return terms
    }

    /// The API takes an array. Multipart form fields are strings, so the terms
    /// go over the wire as a JSON array.
    static func formFieldValue(_ terms: [String]) -> String? {
        guard !terms.isEmpty, let data = try? JSONEncoder().encode(terms) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func wordCount(_ term: String) -> Int {
        term.split(whereSeparator: { $0.isWhitespace }).count
    }
}

enum KeytermsError: LocalizedError, Equatable {
    case tooMany(count: Int)
    case termTooLong(term: String)
    case termHasTooManyWords(term: String)

    var errorDescription: String? {
        switch self {
        case .tooMany(let count):
            return "\(count) key terms — the API accepts at most \(Keyterms.maxCount). Remove \(count - Keyterms.maxCount)."
        case .termTooLong(let term):
            return "\"\(term)\" is \(term.count) characters long. Key terms are limited to \(Keyterms.maxCharacters)."
        case .termHasTooManyWords(let term):
            return "\"\(term)\" has more than \(Keyterms.maxWords) words. Key terms are limited to \(Keyterms.maxWords) words each."
        }
    }
}
