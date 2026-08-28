import XCTest
import Foundation

final class TranscriptFormatterTests: XCTestCase {

    private func word(_ text: String, speaker: String?, type: String? = "word") -> TranscriptionWord {
        TranscriptionWord(type: type, text: text, start: nil, end: nil, speakerId: speaker)
    }

    // MARK: - Grouping

    func testConsecutiveWordsBySameSpeakerBecomeOneTurn() {
        let words = [
            word("Bom", speaker: "speaker_0"),
            word("dia,", speaker: "speaker_0"),
            word("doutora.", speaker: "speaker_0"),
        ]
        XCTAssertEqual(TranscriptFormatter.turns(from: words),
                       [SpeakerTurn(speakerID: "speaker_0", text: "Bom dia, doutora.")])
    }

    func testSpeakerChangeStartsANewTurn() {
        let words = [
            word("Olá", speaker: "speaker_0"),
            word("tudo", speaker: "speaker_1"),
            word("bem", speaker: "speaker_1"),
            word("sim", speaker: "speaker_0"),
        ]
        XCTAssertEqual(TranscriptFormatter.turns(from: words), [
            SpeakerTurn(speakerID: "speaker_0", text: "Olá"),
            SpeakerTurn(speakerID: "speaker_1", text: "tudo bem"),
            SpeakerTurn(speakerID: "speaker_0", text: "sim"),
        ])
    }

    /// The whole reason the spec insists on filtering by type: spacing tokens
    /// and audio events would otherwise land in the middle of sentences.
    func testSpacingAndAudioEventEntriesAreDropped() {
        let words = [
            word("Olá", speaker: "speaker_0"),
            word(" ", speaker: "speaker_0", type: "spacing"),
            word("(laughter)", speaker: "speaker_0", type: "audio_event"),
            word("mundo", speaker: "speaker_0"),
        ]
        XCTAssertEqual(TranscriptFormatter.turns(from: words),
                       [SpeakerTurn(speakerID: "speaker_0", text: "Olá mundo")])
    }

    /// A spacing entry attributed to a different speaker must not split a turn
    /// that is really one continuous stretch of speech.
    func testSpacingBetweenTwoWordsDoesNotSplitATurn() {
        let words = [
            word("um", speaker: "speaker_0"),
            word(" ", speaker: "speaker_1", type: "spacing"),
            word("dois", speaker: "speaker_0"),
        ]
        XCTAssertEqual(TranscriptFormatter.turns(from: words),
                       [SpeakerTurn(speakerID: "speaker_0", text: "um dois")])
    }

    func testWordsWithoutATypeAreTreatedAsSpeech() {
        let words = [word("um", speaker: "speaker_0", type: nil)]
        XCTAssertEqual(TranscriptFormatter.turns(from: words),
                       [SpeakerTurn(speakerID: "speaker_0", text: "um")])
    }

    func testWordsWithNoSpeakerIDCollapseIntoASingleTurn() {
        let words = [word("um", speaker: nil), word("dois", speaker: nil)]
        XCTAssertEqual(TranscriptFormatter.turns(from: words),
                       [SpeakerTurn(speakerID: nil, text: "um dois")])
    }

    func testEmptyAndWhitespaceOnlyWordsAreIgnored() {
        let words = [
            word("", speaker: "speaker_0"),
            word("   ", speaker: "speaker_0"),
            word("olá", speaker: "speaker_0"),
        ]
        XCTAssertEqual(TranscriptFormatter.turns(from: words),
                       [SpeakerTurn(speakerID: "speaker_0", text: "olá")])
    }

    func testEmptyInputProducesNoTurns() {
        XCTAssertEqual(TranscriptFormatter.turns(from: []), [])
    }

    // MARK: - Labels

    func testSpeakerLabelsAreOneIndexedForHumans() {
        XCTAssertEqual(TranscriptFormatter.label(for: "speaker_0"), "Speaker 1")
        XCTAssertEqual(TranscriptFormatter.label(for: "speaker_1"), "Speaker 2")
        XCTAssertEqual(TranscriptFormatter.label(for: "speaker_11"), "Speaker 12")
    }

    func testUnrecognisedSpeakerIDsAreShownUnchanged() {
        XCTAssertEqual(TranscriptFormatter.label(for: "agent"), "agent")
        XCTAssertEqual(TranscriptFormatter.label(for: "speaker_x"), "speaker_x")
        XCTAssertEqual(TranscriptFormatter.label(for: nil), "Unknown")
        XCTAssertEqual(TranscriptFormatter.label(for: ""), "Unknown")
    }

    // MARK: - Rendering

    func testFormattedTranscriptShape() {
        let words = [
            word("Bom", speaker: "speaker_0"),
            word("dia.", speaker: "speaker_0"),
            word("Olá.", speaker: "speaker_1"),
        ]
        let expected = """
        Speaker 1:
        Bom dia.

        Speaker 2:
        Olá.
        """
        XCTAssertEqual(TranscriptFormatter.format(words: words, fallbackText: "ignored"), expected)
    }

    func testFallsBackToFlatTextWhenThereAreNoWords() {
        XCTAssertEqual(TranscriptFormatter.format(words: [], fallbackText: "  Bom dia.  "), "Bom dia.")
        XCTAssertEqual(TranscriptFormatter.format(words: nil, fallbackText: "Bom dia."), "Bom dia.")
    }

    func testFallsBackWhenEveryEntryIsANonWord() {
        let words = [word(" ", speaker: "speaker_0", type: "spacing")]
        XCTAssertEqual(TranscriptFormatter.format(words: words, fallbackText: "Bom dia."), "Bom dia.")
    }

    // MARK: - Speaker discovery

    func testSpeakerIDsAreReturnedInOrderOfFirstAppearance() {
        let words = [
            word("a", speaker: "speaker_1"),
            word("b", speaker: "speaker_0"),
            word("c", speaker: "speaker_1"),
            word("d", speaker: "speaker_2", type: "audio_event"),
        ]
        XCTAssertEqual(TranscriptFormatter.speakerIDs(in: words), ["speaker_1", "speaker_0"])
    }
}

// MARK: - Response decoding

final class TranscriptionResponseTests: XCTestCase {

    func testDecodesTheDocumentedResponseShape() throws {
        let json = """
        {
          "language_code": "por",
          "language_probability": 0.98,
          "text": "Bom dia.",
          "audio_duration_secs": 12.5,
          "words": [
            {"text": "Bom", "start": 0.1, "end": 0.4, "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "start": 0.4, "end": 0.4, "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "dia.", "start": 0.4, "end": 0.8, "type": "word", "speaker_id": "speaker_0"}
          ]
        }
        """
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.text, "Bom dia.")
        XCTAssertEqual(response.languageCode, "por")
        XCTAssertEqual(response.languageProbability, 0.98)
        XCTAssertEqual(response.audioDurationSecs, 12.5)
        XCTAssertEqual(response.words?.count, 3)
        XCTAssertEqual(response.words?.first?.speakerId, "speaker_0")
        XCTAssertEqual(TranscriptFormatter.format(words: response.words, fallbackText: response.text),
                       "Speaker 1:\nBom dia.")
    }

    /// Unknown and missing optional fields must not cost the user a transcript.
    func testDecodesAMinimalResponseAndToleratesNewFields() throws {
        let json = #"{"text": "Bom dia.", "some_future_field": 3}"#
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.text, "Bom dia.")
        XCTAssertNil(response.words)
        XCTAssertNil(response.languageCode)
    }
}

// MARK: - Error mapping

final class TranscriptionErrorTests: XCTestCase {

    func testStatusCodesMapToActionableErrors() {
        let empty = Data()
        assertMessage(TranscriptionService.error(forStatus: 401, body: empty), contains: "401")
        assertMessage(TranscriptionService.error(forStatus: 402, body: empty), contains: "quota")
        assertMessage(TranscriptionService.error(forStatus: 429, body: empty), contains: "Rate limited")
        assertMessage(TranscriptionService.error(forStatus: 413, body: empty), contains: "too large")
        assertMessage(TranscriptionService.error(forStatus: 415, body: empty), contains: "decode")
        assertMessage(TranscriptionService.error(forStatus: 500, body: empty), contains: "500")
    }

    func testServerDetailIsSurfacedToTheUser() {
        let body = Data(#"{"detail": {"status": "invalid_api_key", "message": "Invalid API key"}}"#.utf8)
        assertMessage(TranscriptionService.error(forStatus: 401, body: body), contains: "Invalid API key")
    }

    func testStringDetailIsSurfaced() {
        let body = Data(#"{"detail": "Not enough credits"}"#.utf8)
        assertMessage(TranscriptionService.error(forStatus: 402, body: body), contains: "Not enough credits")
    }

    func testValidationArrayDetailIsSurfaced() {
        let body = Data(#"{"detail": [{"msg": "field required", "loc": ["body", "file"]}]}"#.utf8)
        assertMessage(TranscriptionService.error(forStatus: 422, body: body), contains: "field required")
    }

    func testNonJSONBodyIsSurfacedRaw() {
        XCTAssertEqual(TranscriptionService.errorMessage(from: Data("Bad Gateway".utf8)), "Bad Gateway")
    }

    func testEmptyBodyHasNoDetail() {
        XCTAssertNil(TranscriptionService.errorMessage(from: Data()))
    }

    func testURLErrorsMapToDistinctCases() {
        assertMessage(TranscriptionService.translate(URLError(.timedOut)), contains: "timed out")
        assertMessage(TranscriptionService.translate(URLError(.notConnectedToInternet)),
                      contains: "Cannot reach api.elevenlabs.io")
    }

    func testFileTooLargeReportsBothSizes() {
        let error = TranscriptionError.fileTooLarge(bytes: 6_000_000_000, limit: TranscriptionService.maxUploadBytes)
        assertMessage(error, contains: "GB")
    }

    private func assertMessage(_ error: TranscriptionError,
                               contains needle: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains(needle),
                      "Expected \"\(needle)\" in: \(message)", file: file, line: line)
    }
}

// MARK: - Speaker naming

final class SpeakerNamingTests: XCTestCase {

    private func turn(_ text: String, _ speaker: String?) -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, text: text)
    }

    func testAnAssignedNameReplacesTheDefaultLabel() {
        XCTAssertEqual(TranscriptFormatter.displayName(for: "speaker_0",
                                                       names: ["speaker_0": "Lilian"]),
                       "Lilian")
    }

    func testAnUnnamedSpeakerKeepsItsNumberedLabel() {
        XCTAssertEqual(TranscriptFormatter.displayName(for: "speaker_1", names: [:]), "Speaker 2")
        XCTAssertEqual(TranscriptFormatter.displayName(for: "speaker_1",
                                                       names: ["speaker_0": "Lilian"]),
                       "Speaker 2")
    }

    /// Clearing the field must return the speaker to its default rather than
    /// leaving a nameless row.
    func testABlankNameFallsBackToTheDefaultLabel() {
        XCTAssertEqual(TranscriptFormatter.displayName(for: "speaker_0", names: ["speaker_0": ""]),
                       "Speaker 1")
        XCTAssertEqual(TranscriptFormatter.displayName(for: "speaker_0", names: ["speaker_0": "   "]),
                       "Speaker 1")
    }

    func testNamesAreTrimmed() {
        XCTAssertEqual(TranscriptFormatter.displayName(for: "speaker_0",
                                                       names: ["speaker_0": "  João  "]),
                       "João")
    }

    func testRenderedTranscriptUsesAssignedNames() {
        let turns = [turn("Bom dia.", "speaker_0"), turn("Oi.", "speaker_1")]
        let names = ["speaker_0": "Lilian", "speaker_1": "João"]
        XCTAssertEqual(TranscriptFormatter.format(turns: turns, names: names, fallbackText: ""),
                       "Lilian:\nBom dia.\n\nJoão:\nOi.")
    }

    func testPartiallyNamedTranscriptMixesNamesAndDefaults() {
        let turns = [turn("Bom dia.", "speaker_0"), turn("Oi.", "speaker_1")]
        XCTAssertEqual(TranscriptFormatter.format(turns: turns,
                                                  names: ["speaker_0": "Lilian"],
                                                  fallbackText: ""),
                       "Lilian:\nBom dia.\n\nSpeaker 2:\nOi.")
    }

    func testFormattingStillFallsBackWhenThereAreNoTurns() {
        XCTAssertEqual(TranscriptFormatter.format(turns: [],
                                                  names: ["speaker_0": "Lilian"],
                                                  fallbackText: "  Bom dia. "),
                       "Bom dia.")
    }

    func testSpeakerIDsFromTurnsAreInOrderOfFirstAppearance() {
        let turns = [turn("a", "speaker_1"), turn("b", "speaker_0"), turn("c", "speaker_1")]
        XCTAssertEqual(TranscriptFormatter.speakerIDs(in: turns), ["speaker_1", "speaker_0"])
    }

    func testTurnsWithoutASpeakerContributeNoRowToThePeoplePanel() {
        XCTAssertEqual(TranscriptFormatter.speakerIDs(in: [turn("a", nil)]), [])
    }
}

// MARK: - Speaker colours

final class SpeakerColorTests: XCTestCase {

    func testColoursAreHandedOutInOrderOfFirstAppearance() {
        let colors = SpeakerColor.assign(to: ["speaker_1", "speaker_0"])
        XCTAssertEqual(colors["speaker_1"], .blue)
        XCTAssertEqual(colors["speaker_0"], .orange)
    }

    func testEverySpeakerInATypicalMeetingGetsADistinctColour() {
        let ids = (0..<SpeakerColor.allCases.count).map { "speaker_\($0)" }
        let assigned = SpeakerColor.assign(to: ids)
        XCTAssertEqual(Set(assigned.values).count, SpeakerColor.allCases.count)
    }

    /// More speakers than colours is unlikely but must not crash.
    func testColoursWrapAroundBeyondThePalette() {
        let count = SpeakerColor.allCases.count
        XCTAssertEqual(SpeakerColor.forSpeaker(atIndex: count), .blue)
        XCTAssertEqual(SpeakerColor.forSpeaker(atIndex: count + 1), .orange)
        XCTAssertEqual(SpeakerColor.forSpeaker(atIndex: -1), SpeakerColor.allCases.last)
    }

    func testNoSpeakersMeansNoColours() {
        XCTAssertTrue(SpeakerColor.assign(to: []).isEmpty)
    }

    /// Saved transcripts store these raw values, so reordering the palette
    /// would silently recolour every speaker on disk. New colours go on the
    /// end; this test is what makes that rule enforceable.
    func testPaletteRawValuesAreStable() {
        XCTAssertEqual(SpeakerColor.blue.rawValue, 0)
        XCTAssertEqual(SpeakerColor.orange.rawValue, 1)
        XCTAssertEqual(SpeakerColor.green.rawValue, 2)
        XCTAssertEqual(SpeakerColor.purple.rawValue, 3)
        XCTAssertEqual(SpeakerColor.pink.rawValue, 4)
        XCTAssertEqual(SpeakerColor.teal.rawValue, 5)
        XCTAssertEqual(SpeakerColor.indigo.rawValue, 6)
        XCTAssertEqual(SpeakerColor.brown.rawValue, 7)
        XCTAssertEqual(SpeakerColor.red.rawValue, 8)
        XCTAssertEqual(SpeakerColor.burgundy.rawValue, 9)
    }

    func testEveryColourHasAName() {
        for colour in SpeakerColor.allCases {
            XCTAssertFalse(colour.displayName.isEmpty)
        }
    }
}

// MARK: - Reassigning speakers

final class SpeakerEditorTests: XCTestCase {

    private func turn(_ text: String, _ speaker: String?) -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, text: text)
    }

    private var sample: [SpeakerTurn] {
        [turn("um", "speaker_0"), turn("dois", "speaker_1"), turn("três", "speaker_0")]
    }

    func testAssigningMovesOnlyTheChosenSegment() {
        let edited = SpeakerEditor.assigning(sample, at: 1, to: "speaker_0")
        XCTAssertEqual(edited.map(\.speakerID), ["speaker_0", "speaker_0", "speaker_0"])
        XCTAssertEqual(edited.map(\.text), ["um", "dois", "três"])
    }

    func testAssigningOutOfRangeChangesNothing() {
        XCTAssertEqual(SpeakerEditor.assigning(sample, at: 99, to: "speaker_1"), sample)
        XCTAssertEqual(SpeakerEditor.assigning(sample, at: -1, to: "speaker_1"), sample)
    }

    func testReassigningAllMovesEverySegmentOfOneSpeaker() {
        let edited = SpeakerEditor.reassigningAll(sample, from: "speaker_0", to: "speaker_1")
        XCTAssertEqual(edited.map(\.speakerID), ["speaker_1", "speaker_1", "speaker_1"])
    }

    func testReassigningAllLeavesOtherSpeakersAlone() {
        let edited = SpeakerEditor.reassigningAll(sample, from: "speaker_1", to: "speaker_0")
        XCTAssertEqual(edited.map(\.speakerID), ["speaker_0", "speaker_0", "speaker_0"])
        XCTAssertEqual(SpeakerEditor.reassigningAll(sample, from: "nobody", to: "speaker_0"), sample)
    }

    func testReassigningAllCanCollectUndiarizedSegments() {
        let turns = [turn("um", nil), turn("dois", "speaker_0")]
        let edited = SpeakerEditor.reassigningAll(turns, from: nil, to: "speaker_0")
        XCTAssertEqual(edited.map(\.speakerID), ["speaker_0", "speaker_0"])
    }

    func testNextSpeakerIDFollowsTheAPINumbering() {
        XCTAssertEqual(SpeakerEditor.nextSpeakerID(notIn: []), "speaker_0")
        XCTAssertEqual(SpeakerEditor.nextSpeakerID(notIn: ["speaker_0", "speaker_1"]), "speaker_2")
    }

    func testNextSpeakerIDFillsAGapRatherThanColliding() {
        XCTAssertEqual(SpeakerEditor.nextSpeakerID(notIn: ["speaker_1", "speaker_2"]), "speaker_0")
        XCTAssertEqual(SpeakerEditor.nextSpeakerID(notIn: ["speaker_0", "speaker_2"]), "speaker_1")
    }

    func testSegmentCountDecidesWhetherASpeakerCanBeRemoved() {
        XCTAssertEqual(SpeakerEditor.segmentCount(for: "speaker_0", in: sample), 2)
        XCTAssertEqual(SpeakerEditor.segmentCount(for: "speaker_9", in: sample), 0)
    }
}

// MARK: - Merging for output

final class TurnMergingTests: XCTestCase {

    private func turn(_ text: String, _ speaker: String?) -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, text: text)
    }

    func testAlternatingSpeakersAreLeftAlone() {
        let turns = [turn("um", "speaker_0"), turn("dois", "speaker_1")]
        XCTAssertEqual(TranscriptFormatter.merged(turns), turns)
    }

    func testAdjacentSegmentsBySameSpeakerAreJoined() {
        let turns = [turn("um", "speaker_0"), turn("dois", "speaker_0"), turn("três", "speaker_1")]
        XCTAssertEqual(TranscriptFormatter.merged(turns),
                       [turn("um dois", "speaker_0"), turn("três", "speaker_1")])
    }

    func testAWholeRunIsJoinedIntoOne() {
        let turns = [turn("um", "speaker_0"), turn("dois", "speaker_0"), turn("três", "speaker_0")]
        XCTAssertEqual(TranscriptFormatter.merged(turns), [turn("um dois três", "speaker_0")])
    }

    func testEmptyInputMergesToNothing() {
        XCTAssertEqual(TranscriptFormatter.merged([]), [])
    }

    /// The point of merging on output only: after reassigning the middle
    /// segment the reader sees one block, but the three segments are still
    /// there, so the edit can be undone by reassigning it back.
    func testReassignmentReadsAsOneBlockButStaysReversible() {
        let original = [turn("um", "speaker_0"), turn("dois", "speaker_1"), turn("três", "speaker_0")]
        let names = ["speaker_0": "Lilian", "speaker_1": "João"]

        let edited = SpeakerEditor.assigning(original, at: 1, to: "speaker_0")
        XCTAssertEqual(edited.count, 3, "segments must survive the reassignment")
        XCTAssertEqual(TranscriptFormatter.format(turns: edited, names: names, fallbackText: ""),
                       "Lilian:\num dois três")

        let undone = SpeakerEditor.assigning(edited, at: 1, to: "speaker_1")
        XCTAssertEqual(undone, original)
        XCTAssertEqual(TranscriptFormatter.format(turns: undone, names: names, fallbackText: ""),
                       "Lilian:\num\n\nJoão:\ndois\n\nLilian:\ntrês")
    }

    func testMarkdownAlsoMergesAdjacentSegments() {
        let turns = [turn("um", "speaker_0"), turn("dois", "speaker_0")]
        XCTAssertEqual(TranscriptFormatter.markdown(title: "",
                                                    turns: turns,
                                                    names: ["speaker_0": "Lilian"],
                                                    fallbackText: ""),
                       "**Lilian**\num dois\n")
    }
}

// MARK: - Badges and deleting a speaker

final class SpeakerBadgeTests: XCTestCase {

    func testANamedSpeakerGetsTheirFirstLetter() {
        XCTAssertEqual(TranscriptFormatter.initial(for: "speaker_0", names: ["speaker_0": "Lilian"]), "L")
        XCTAssertEqual(TranscriptFormatter.initial(for: "speaker_0", names: ["speaker_0": "João"]), "J")
    }

    func testTheLetterIsUppercasedAndIgnoresLeadingSpace() {
        XCTAssertEqual(TranscriptFormatter.initial(for: "speaker_0", names: ["speaker_0": "  renée"]), "R")
    }

    /// "S" for every "Speaker N" would identify nobody, so an unnamed speaker
    /// is badged with their number instead.
    func testAnUnnamedSpeakerGetsTheirNumber() {
        XCTAssertEqual(TranscriptFormatter.initial(for: "speaker_0", names: [:]), "1")
        XCTAssertEqual(TranscriptFormatter.initial(for: "speaker_2", names: [:]), "3")
        XCTAssertEqual(TranscriptFormatter.initial(for: "speaker_0", names: ["speaker_0": "   "]), "1")
    }

    func testAnUnrecognisedSpeakerGetsAQuestionMark() {
        XCTAssertEqual(TranscriptFormatter.initial(for: nil, names: [:]), "?")
        XCTAssertEqual(TranscriptFormatter.initial(for: "agent", names: [:]), "?")
    }
}

final class DeletingASpeakerTests: XCTestCase {

    private func turn(_ text: String, _ speaker: String?) -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, text: text)
    }

    /// Deleting a speaker must never delete what they said.
    func testTheirSegmentsAreDetachedNotDestroyed() {
        let turns = [turn("um", "speaker_0"), turn("dois", "speaker_1"), turn("três", "speaker_0")]
        let after = SpeakerEditor.unassigning(turns, speakerID: "speaker_0")

        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after.map(\.text), ["um", "dois", "três"])
        XCTAssertEqual(after.map(\.speakerID), [nil, "speaker_1", nil])
    }

    func testDetachedSegmentsReadAsUnknown() {
        let after = SpeakerEditor.unassigning([turn("um", "speaker_0")], speakerID: "speaker_0")
        XCTAssertEqual(TranscriptFormatter.format(turns: after, names: [:], fallbackText: ""),
                       "Unknown:\num")
    }

    func testDeletingSomeoneElseLeavesThemAlone() {
        let turns = [turn("um", "speaker_0")]
        XCTAssertEqual(SpeakerEditor.unassigning(turns, speakerID: "speaker_9"), turns)
    }

    /// The segments are recoverable: an Unknown run can be handed to anyone.
    func testUnknownSegmentsCanBeReassignedBack() {
        let turns = [turn("um", "speaker_0"), turn("dois", "speaker_0")]
        let orphaned = SpeakerEditor.unassigning(turns, speakerID: "speaker_0")
        let recovered = SpeakerEditor.reassigningAll(orphaned, from: nil, to: "speaker_1")
        XCTAssertEqual(recovered.map(\.speakerID), ["speaker_1", "speaker_1"])
    }
}

// MARK: - Editing the text

final class TextEditingTests: XCTestCase {

    private func turn(_ text: String, _ speaker: String?) -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, text: text)
    }

    private var sample: [SpeakerTurn] {
        [turn("um", "speaker_0"), turn("dois", "speaker_1"), turn("três", "speaker_0")]
    }

    func testReplacingEditsOnlyThatSegment() {
        let edited = SpeakerEditor.replacingText(sample, at: 1, with: "DOIS")
        XCTAssertEqual(edited.map(\.text), ["um", "DOIS", "três"])
    }

    func testTheSpeakerSurvivesAnEdit() {
        let edited = SpeakerEditor.replacingText(sample, at: 1, with: "DOIS")
        XCTAssertEqual(edited.map(\.speakerID), ["speaker_0", "speaker_1", "speaker_0"])
    }

    func testReplacingOutOfRangeChangesNothing() {
        XCTAssertEqual(SpeakerEditor.replacingText(sample, at: 9, with: "x"), sample)
        XCTAssertEqual(SpeakerEditor.replacingText(sample, at: -1, with: "x"), sample)
    }

    func testCommittingTrimsSurroundingWhitespace() {
        let typed = SpeakerEditor.replacingText(sample, at: 1, with: "  dois  ")
        XCTAssertEqual(SpeakerEditor.committingText(typed, at: 1), sample)
    }

    /// Emptying a segment is how you delete one.
    func testCommittingAnEmptiedSegmentRemovesIt() {
        for emptied in ["", "   ", "\n "] {
            let typed = SpeakerEditor.replacingText(sample, at: 1, with: emptied)
            XCTAssertEqual(SpeakerEditor.committingText(typed, at: 1),
                           [turn("um", "speaker_0"), turn("três", "speaker_0")])
        }
    }

    func testCommittingOutOfRangeChangesNothing() {
        XCTAssertEqual(SpeakerEditor.committingText(sample, at: 9), sample)
    }

    func testCommittingUnchangedTextIsIdentity() {
        XCTAssertEqual(SpeakerEditor.committingText(sample, at: 0), sample)
    }

    /// Deleting the middle segment leaves two adjacent segments by the same
    /// speaker, which the output joins into one block.
    func testNeighboursJoinOnOutputAfterASegmentIsDeleted() {
        let typed = SpeakerEditor.replacingText(sample, at: 1, with: "")
        let after = SpeakerEditor.committingText(typed, at: 1)
        XCTAssertEqual(TranscriptFormatter.format(turns: after,
                                                  names: ["speaker_0": "Lilian"],
                                                  fallbackText: ""),
                       "Lilian:\num três")
    }

    func testEditedTextReachesTheMarkdown() {
        let edited = SpeakerEditor.replacingText([turn("vinte e cinco barra cinco", "speaker_0")],
                                                 at: 0,
                                                 with: "vinte barra cinco")
        XCTAssertEqual(TranscriptFormatter.markdown(title: "",
                                                    turns: edited,
                                                    names: ["speaker_0": "Lilian"],
                                                    fallbackText: ""),
                       "**Lilian**\nvinte barra cinco\n")
    }
}
