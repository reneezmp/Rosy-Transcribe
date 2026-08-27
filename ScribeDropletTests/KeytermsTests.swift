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

    func testTermLengthLimitIsFiftyCharacters() {
        let fifty = String(repeating: "a", count: 50)
        XCTAssertNoThrow(try Keyterms.validate([fifty]))

        let fiftyOne = String(repeating: "a", count: 51)
        XCTAssertThrowsError(try Keyterms.validate([fiftyOne])) { error in
            XCTAssertEqual(error as? KeytermsError, .termTooLong(term: fiftyOne))
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
        let fifty = String(repeating: "ç", count: 50)
        XCTAssertNoThrow(try Keyterms.validate([fifty]))
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

    // MARK: - Wire format

    func testNoTermsMeansNoParameterAtAll() {
        // Sending an empty array is not the same as sending nothing.
        XCTAssertNil(Keyterms.formFieldValue([]))
    }

    func testTermsAreEncodedAsAJSONArray() {
        XCTAssertEqual(Keyterms.formFieldValue(["proferida", "averbação"]),
                       #"["proferida","averbação"]"#)
    }

    func testJSONEncodingSurvivesQuotesAndBackslashes() throws {
        let value = try XCTUnwrap(Keyterms.formFieldValue([#"a "quoted" term"#]))
        let decoded = try JSONDecoder().decode([String].self, from: Data(value.utf8))
        XCTAssertEqual(decoded, [#"a "quoted" term"#])
    }

    func testAccentedTermsRoundTripThroughJSON() throws {
        let terms = ["averbação", "ineficácia relativa", "João"]
        let value = try XCTUnwrap(Keyterms.formFieldValue(terms))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(value.utf8)), terms)
    }

    /// The end-to-end shape: a glossary must arrive as one well-formed form
    /// field, with its JSON and its accents intact after multipart encoding.
    func testKeytermsSurviveTheMultipartEnvelope() throws {
        let terms = try Keyterms.validated("proferida, averbação, embargos de terceiros")
        var fields = ["model_id": "scribe_v2", "diarize": "true"]
        fields["keyterms"] = try XCTUnwrap(Keyterms.formFieldValue(terms))

        let body = MultipartBuilder(boundary: "B").body(fields: fields,
                                                        fileFieldName: "file",
                                                        fileName: "a.mp3",
                                                        fileMIMEType: "audio/mpeg",
                                                        fileData: Data("AUDIO".utf8))
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"keyterms\"\r\n\r\n"
                                    + #"["proferida","averbação","embargos de terceiros"]"# + "\r\n"))
    }
}
