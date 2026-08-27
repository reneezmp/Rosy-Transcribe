import XCTest
import Foundation

final class KeytermsTests: XCTestCase {

    // MARK: - Parsing

    func testSplitsOnCommas() {
        XCTAssertEqual(Keyterms.parse("proferida, averbação, ineficácia relativa"),
                       ["proferida", "averbação", "ineficácia relativa"])
    }

    func testSplitsOnNewlinesToo() {
        XCTAssertEqual(Keyterms.parse("proferida\naverbação\nembargos de terceiros"),
                       ["proferida", "averbação", "embargos de terceiros"])
    }

    func testMixedSeparatorsAndUntidyWhitespace() {
        XCTAssertEqual(Keyterms.parse("  proferida ,\n\n  averbação,,  \n , ineficácia  "),
                       ["proferida", "averbação", "ineficácia"])
    }

    func testDuplicatesAreRemovedKeepingTypedOrder() {
        XCTAssertEqual(Keyterms.parse("b, a, b, c, a"), ["b", "a", "c"])
    }

    func testEmptyInputProducesNoTerms() {
        XCTAssertEqual(Keyterms.parse(""), [])
        XCTAssertEqual(Keyterms.parse("   \n , , \n "), [])
    }

    /// Multi-word terms are the point — "embargos de terceiros" must survive
    /// as one term rather than being split on its spaces.
    func testMultiWordTermsSurviveIntact() {
        XCTAssertEqual(Keyterms.parse("embargos de terceiros"), ["embargos de terceiros"])
    }

    // MARK: - Limits

    func testAtMostOneHundredTerms() {
        let hundred = (1...100).map { "term\($0)" }
        XCTAssertNoThrow(try Keyterms.validate(hundred))

        let hundredAndOne = (1...101).map { "term\($0)" }
        XCTAssertThrowsError(try Keyterms.validate(hundredAndOne)) { error in
            XCTAssertEqual(error as? KeytermsError, .tooMany(count: 101))
        }
    }

    /// The server rejects with "All keywords must be less than 50 characters",
    /// so 50 itself is too long even though the docs say "≤50".
    func testTermLengthLimitIsUnderFiftyCharacters() {
        let fortyNine = String(repeating: "a", count: 49)
        XCTAssertNoThrow(try Keyterms.validate([fortyNine]))

        let fifty = String(repeating: "a", count: 50)
        XCTAssertThrowsError(try Keyterms.validate([fifty])) { error in
            XCTAssertEqual(error as? KeytermsError, .termTooLong(term: fifty))
        }
    }

    func testWordCountLimitIsFiveWords() {
        XCTAssertNoThrow(try Keyterms.validate(["um dois três quatro cinco"]))

        let six = "um dois três quatro cinco seis"
        XCTAssertThrowsError(try Keyterms.validate([six])) { error in
            XCTAssertEqual(error as? KeytermsError, .termHasTooManyWords(term: six))
        }
    }

    /// Accented characters are one character each, not one per byte.
    func testLengthIsCountedInCharactersNotBytes() {
        let fortyNine = String(repeating: "ç", count: 49)
        XCTAssertNoThrow(try Keyterms.validate([fortyNine]))
    }

    func testEveryLimitMessageNamesTheOffendingTerm() {
        XCTAssertTrue(KeytermsError.termTooLong(term: "abc").localizedDescription.contains("abc"))
        XCTAssertTrue(KeytermsError.termHasTooManyWords(term: "abc").localizedDescription.contains("abc"))
        XCTAssertTrue(KeytermsError.tooMany(count: 101).localizedDescription.contains("101"))
    }

    func testValidatedParsesAndChecksInOneStep() throws {
        XCTAssertEqual(try Keyterms.validated("proferida, averbação"), ["proferida", "averbação"])
        XCTAssertThrowsError(try Keyterms.validated(String(repeating: "a", count: 51)))
    }

    // MARK: - Request shape

    /// Regression. The glossary first went out as a JSON array in a single
    /// part; the server measured that whole 85-character array as one keyword
    /// and rejected the request with "All keywords must be less than 50
    /// characters". An array parameter over multipart is the same name
    /// repeated, one part per term.
    func testKeytermsAreRepeatedPartsRatherThanAJSONArray() throws {
        let terms = try Keyterms.validated("proferida, averbação, Dr. Christopher")
        let fields = TranscriptionService.formFields(languageCode: "por", keyterms: terms)

        XCTAssertEqual(fields.filter { $0.name == "keyterms" },
                       [MultipartField("keyterms", "proferida"),
                        MultipartField("keyterms", "averbação"),
                        MultipartField("keyterms", "Dr. Christopher")])
    }

    func testKeytermsReachTheEnvelopeAsOneBarePartPerTerm() throws {
        let terms = try Keyterms.validated("proferida, averbação, Dr. Christopher")
        let body = MultipartBuilder(boundary: "B").body(
            fields: TranscriptionService.formFields(languageCode: "por", keyterms: terms),
            fileFieldName: "file",
            fileName: "a.mp3",
            fileMIMEType: "audio/mpeg",
            fileData: Data("AUDIO".utf8))
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertEqual(text.components(separatedBy: "name=\"keyterms\"").count - 1, 3)
        for term in terms {
            XCTAssertTrue(text.contains("name=\"keyterms\"\r\n\r\n\(term)\r\n"),
                          "expected a bare part for \(term)")
        }
        XCTAssertFalse(text.contains("["), "no JSON array should appear anywhere in the body")
    }

    func testEmptyGlossarySendsNoKeytermsFieldAtAll() {
        let fields = TranscriptionService.formFields(languageCode: "por", keyterms: [])
        XCTAssertFalse(fields.contains { $0.name == "keyterms" })
    }

    func testAutoDetectSendsNoLanguageCodeField() {
        let fields = TranscriptionService.formFields(languageCode: nil, keyterms: [])
        XCTAssertFalse(fields.contains { $0.name == "language_code" })
    }

    func testTheConstantFieldsAreAlwaysPresent() {
        let fields = TranscriptionService.formFields(languageCode: "por", keyterms: ["a"])
        XCTAssertEqual(fields.first, MultipartField("model_id", "scribe_v2"))
        XCTAssertTrue(fields.contains(MultipartField("diarize", "true")))
        XCTAssertTrue(fields.contains(MultipartField("timestamps_granularity", "word")))
        XCTAssertTrue(fields.contains(MultipartField("language_code", "por")))
    }
}
