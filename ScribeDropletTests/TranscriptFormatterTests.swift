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
        XCTAssertEqual(TranscriptFormatter.label(for: nil), "Speaker")
        XCTAssertEqual(TranscriptFormatter.label(for: ""), "Speaker")
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
