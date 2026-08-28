import XCTest
import Foundation

final class TranscriptSearchTests: XCTestCase {

    private func turn(_ text: String, _ speaker: String? = "speaker_0") -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, text: text)
    }

    private func matched(_ query: String, _ turns: [SpeakerTurn]) -> [String] {
        TranscriptSearch.matches(for: query, in: turns).map { match in
            String(turns[match.turnIndex].text[match.range])
        }
    }

    // MARK: - Finding

    func testFindsASingleMatch() {
        let turns = [turn("Bom dia, doutora.")]
        let matches = TranscriptSearch.matches(for: "dia", in: turns)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.turnIndex, 0)
        XCTAssertEqual(matched("dia", turns), ["dia"])
    }

    func testFindsEveryOccurrenceWithinOneSegment() {
        let turns = [turn("essa, essa, essa certidão")]
        XCTAssertEqual(matched("essa", turns), ["essa", "essa", "essa"])
    }

    func testMatchesAreReturnedInReadingOrder() {
        let turns = [turn("um dois"), turn("dois um"), turn("dois")]
        let matches = TranscriptSearch.matches(for: "dois", in: turns)
        XCTAssertEqual(matches.map(\.turnIndex), [0, 1, 2])
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(matched("PENHORA", [turn("a penhora do imóvel")]), ["penhora"])
        XCTAssertEqual(matched("bom", [turn("Bom dia")]), ["Bom"])
    }

    /// The one that matters for Portuguese: no reaching for accent keys.
    func testSearchIsDiacriticInsensitive() {
        XCTAssertEqual(matched("averbacao", [turn("essa averbação vinte")]), ["averbação"])
        XCTAssertEqual(matched("ineficacia", [turn("declaração de ineficácia relativa")]),
                       ["ineficácia"])
        XCTAssertEqual(matched("Joao", [turn("O dia 12 é o seu, João?")]), ["João"])
    }

    func testAnAccentedQueryStillFindsAccentedText() {
        XCTAssertEqual(matched("averbação", [turn("essa averbação vinte")]), ["averbação"])
    }

    // MARK: - Nothing to find

    func testAnEmptyQueryMatchesNothing() {
        let turns = [turn("Bom dia")]
        XCTAssertTrue(TranscriptSearch.matches(for: "", in: turns).isEmpty)
        XCTAssertTrue(TranscriptSearch.matches(for: "   ", in: turns).isEmpty)
    }

    func testAQueryThatIsNotThereMatchesNothing() {
        XCTAssertTrue(TranscriptSearch.matches(for: "usucapião", in: [turn("Bom dia")]).isEmpty)
    }

    func testSearchingAnEmptyTranscriptIsSafe() {
        XCTAssertTrue(TranscriptSearch.matches(for: "dia", in: []).isEmpty)
        XCTAssertTrue(TranscriptSearch.matches(for: "dia", in: [turn("")]).isEmpty)
    }

    /// A repeated needle must not make the scan stand still.
    func testOverlappingCandidatesTerminate() {
        XCTAssertEqual(matched("aa", [turn("aaaa")]).count, 2)
        XCTAssertEqual(matched("a", [turn("aaa")]).count, 3)
    }

    func testTheQueryIsTrimmedBeforeSearching() {
        XCTAssertEqual(matched("  dia  ", [turn("Bom dia")]), ["dia"])
    }

    func testAMultiWordQueryWorks() {
        XCTAssertEqual(matched("embargos de terceiros",
                               [turn("nos autos de embargos de terceiros.")]),
                       ["embargos de terceiros"])
    }

    // MARK: - Grouping

    func testRangesAreGroupedBySegment() {
        let turns = [turn("dois dois"), turn("um"), turn("dois")]
        let grouped = TranscriptSearch.rangesByTurn(TranscriptSearch.matches(for: "dois", in: turns))

        XCTAssertEqual(grouped[0]?.count, 2)
        XCTAssertNil(grouped[1])
        XCTAssertEqual(grouped[2]?.count, 1)
    }

    func testGroupingNothingGivesNothing() {
        XCTAssertTrue(TranscriptSearch.rangesByTurn([]).isEmpty)
    }

    /// The ranges must index the segment they were found in, so a row can
    /// highlight with them directly.
    func testRangesAddressTheirOwnSegment() {
        let turns = [turn("um dois"), turn("três dois")]
        for match in TranscriptSearch.matches(for: "dois", in: turns) {
            XCTAssertEqual(String(turns[match.turnIndex].text[match.range]), "dois")
        }
    }
}
