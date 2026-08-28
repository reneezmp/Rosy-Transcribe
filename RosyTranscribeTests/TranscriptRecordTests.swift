import XCTest
import Foundation

// MARK: - Markdown export

final class MarkdownExportTests: XCTestCase {

    private func turn(_ text: String, _ speaker: String?) -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, text: text)
    }

    private let names = ["speaker_0": "Clara", "speaker_1": "Ana"]

    func testMarkdownMatchesTheRequestedShape() {
        let turns = [turn("Blablablabla", "speaker_0"),
                     turn("Blablablabla", "speaker_1"),
                     turn("Blablabla", "speaker_0")]
        let expected = """
        # Title of the meeting

        **Clara**
        Blablablabla

        **Ana**
        Blablablabla

        **Clara**
        Blablabla

        """
        XCTAssertEqual(TranscriptFormatter.markdown(title: "Title of the meeting",
                                                    turns: turns,
                                                    names: names,
                                                    fallbackText: ""),
                       expected)
    }

    /// A blank title must not leave an empty "# " heading at the top.
    func testABlankTitleProducesNoHeading() {
        let turns = [turn("Bom dia.", "speaker_0")]
        for title in ["", "   ", "\n"] {
            XCTAssertEqual(TranscriptFormatter.markdown(title: title,
                                                        turns: turns,
                                                        names: names,
                                                        fallbackText: ""),
                           "**Clara**\nBom dia.\n")
        }
    }

    func testTheTitleIsTrimmed() {
        let markdown = TranscriptFormatter.markdown(title: "  Reunião  ",
                                                    turns: [turn("Oi.", "speaker_0")],
                                                    names: [:],
                                                    fallbackText: "")
        XCTAssertTrue(markdown.hasPrefix("# Reunião\n\n"))
    }

    func testUnnamedSpeakersKeepTheirNumberedLabel() {
        XCTAssertEqual(TranscriptFormatter.markdown(title: "",
                                                    turns: [turn("Oi.", "speaker_1")],
                                                    names: [:],
                                                    fallbackText: ""),
                       "**Speaker 2**\nOi.\n")
    }

    func testFallsBackToFlatTextUnderTheTitle() {
        XCTAssertEqual(TranscriptFormatter.markdown(title: "Reunião",
                                                    turns: [],
                                                    names: [:],
                                                    fallbackText: "  Bom dia.  "),
                       "# Reunião\n\nBom dia.\n")
    }

    func testNothingToExportProducesJustTheHeadingOrNothing() {
        XCTAssertEqual(TranscriptFormatter.markdown(title: "", turns: [], names: [:], fallbackText: ""), "")
        XCTAssertEqual(TranscriptFormatter.markdown(title: "Reunião", turns: [], names: [:], fallbackText: ""),
                       "# Reunião\n\n")
    }

    func testMarkdownEndsWithExactlyOneNewline() {
        let markdown = TranscriptFormatter.markdown(title: "Reunião",
                                                    turns: [turn("Oi.", "speaker_0")],
                                                    names: names,
                                                    fallbackText: "")
        XCTAssertTrue(markdown.hasSuffix("Oi.\n"))
        XCTAssertFalse(markdown.hasSuffix("\n\n"))
    }
}

// MARK: - Record

final class TranscriptRecordTests: XCTestCase {

    func testDisplayTitlePrefersTheTitle() {
        let record = TranscriptRecord(title: "Reunião", sourceFilename: "audio.m4a")
        XCTAssertEqual(record.displayTitle, "Reunião")
    }

    func testDisplayTitleFallsBackToTheFilenameStem() {
        let record = TranscriptRecord(title: "  ", sourceFilename: "reunião-06-26.m4a")
        XCTAssertEqual(record.displayTitle, "reunião-06-26")
    }

    func testDisplayTitleIsNeverBlank() {
        XCTAssertEqual(TranscriptRecord().displayTitle, "Untitled")
    }

    func testSuggestedFilenameStripsPathSeparators() {
        let record = TranscriptRecord(title: "Reunião 26/08: autos 20/5")
        XCTAssertEqual(record.suggestedFilename, "Reunião 26-08- autos 20-5")
        XCTAssertFalse(record.suggestedFilename.contains("/"))
        XCTAssertFalse(record.suggestedFilename.contains(":"))
    }

    func testSuggestedFilenameIsNeverEmpty() {
        XCTAssertEqual(TranscriptRecord(title: "///").suggestedFilename, "Transcript")
    }

    /// Records written before `speakerOrder` existed must still load — there
    /// are real transcripts on disk from before this field was added.
    func testARecordWithoutSpeakerOrderStillDecodes() throws {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "title": "Reunião",
          "createdAt": "2023-11-14T22:13:20Z",
          "sourceFilename": "reunião.m4a",
          "fallbackText": "Bom dia. Oi.",
          "speakerNames": { "speaker_0": "Ana" },
          "speakerColors": { "speaker_0": 0 },
          "turns": [
            { "speakerID": "speaker_0", "text": "Bom dia." },
            { "speakerID": "speaker_1", "text": "Oi." }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TranscriptRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.title, "Reunião")
        XCTAssertNil(record.speakerOrder)
        // Derived from the turns instead.
        XCTAssertEqual(record.speakers, ["speaker_0", "speaker_1"])
    }

    func testAStoredSpeakerOrderIsPreferredOverDerivingIt() {
        let record = TranscriptRecord(turns: [SpeakerTurn(speakerID: "speaker_0", text: "Oi.")],
                                      speakerOrder: ["speaker_0", "speaker_1"])
        // speaker_1 was added by hand and owns nothing yet.
        XCTAssertEqual(record.speakers, ["speaker_0", "speaker_1"])
    }

    func testHasContent() {
        XCTAssertFalse(TranscriptRecord().hasContent)
        XCTAssertTrue(TranscriptRecord(turns: [SpeakerTurn(speakerID: "speaker_0", text: "Oi.")]).hasContent)
        XCTAssertTrue(TranscriptRecord(fallbackText: "Oi.").hasContent)
    }
}

// MARK: - Store

final class TranscriptStoreTests: XCTestCase {

    private var directory: URL!
    private var store: TranscriptStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RosyTranscribeTests-\(UUID().uuidString)")
        store = TranscriptStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whole seconds: the store encodes dates as ISO 8601, which does not
    /// carry fractional seconds, so `Date()` would not compare equal after a
    /// round trip.
    private func record(_ title: String, at seconds: TimeInterval) -> TranscriptRecord {
        TranscriptRecord(title: title,
                         createdAt: Date(timeIntervalSince1970: seconds),
                         sourceFilename: "reunião.m4a",
                         detectedLanguage: "por (100% confidence)",
                         turns: [SpeakerTurn(speakerID: "speaker_0", text: "Bom dia."),
                                 SpeakerTurn(speakerID: "speaker_1", text: "Oi.")],
                         fallbackText: "Bom dia. Oi.",
                         speakerNames: ["speaker_0": "Ana"],
                         speakerColors: ["speaker_0": .blue, "speaker_1": .orange])
    }

    func testARecordSurvivesSavingAndLoading() throws {
        let original = record("Reunião", at: 1_700_000_000)
        try store.save(original)
        XCTAssertEqual(store.load(), [original])
    }

    func testTheDirectoryIsCreatedOnFirstSave() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.save(record("Reunião", at: 1_700_000_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLoadingAnEmptyOrMissingDirectoryReturnsNothing() {
        XCTAssertEqual(store.load(), [])
    }

    func testRecordsComeBackNewestFirst() throws {
        try store.save(record("oldest", at: 1_000))
        try store.save(record("newest", at: 3_000))
        try store.save(record("middle", at: 2_000))
        XCTAssertEqual(store.load().map(\.title), ["newest", "middle", "oldest"])
    }

    func testSavingAgainUpdatesRatherThanDuplicates() throws {
        var original = record("Reunião", at: 1_700_000_000)
        try store.save(original)
        original.title = "Reunião renomeada"
        try store.save(original)

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Reunião renomeada")
    }

    func testDeleteRemovesOnlyThatRecord() throws {
        let keep = record("keep", at: 2_000)
        let drop = record("drop", at: 1_000)
        try store.save(keep)
        try store.save(drop)

        try store.delete(drop.id)
        XCTAssertEqual(store.load().map(\.title), ["keep"])
    }

    func testDeletingSomethingThatIsNotThereIsNotAnError() {
        XCTAssertNoThrow(try store.delete(UUID()))
    }

    /// One unreadable file must cost one meeting, not the whole library.
    func testAnUnreadableFileIsSkippedRatherThanLosingEverything() throws {
        try store.save(record("good", at: 1_000))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not a record }".utf8)
            .write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))

        XCTAssertEqual(store.load().map(\.title), ["good"])
    }

    func testNonJSONFilesAreIgnored() throws {
        try store.save(record("good", at: 1_000))
        try Data("hello".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        XCTAssertEqual(store.load().count, 1)
    }

    func testSpeakerNamesAndColoursSurviveTheRoundTrip() throws {
        let original = record("Reunião", at: 1_700_000_000)
        try store.save(original)
        let loaded = try XCTUnwrap(store.load().first)

        XCTAssertEqual(loaded.speakerNames["speaker_0"], "Ana")
        XCTAssertEqual(loaded.speakerColors["speaker_1"], .orange)
        XCTAssertEqual(loaded.turns, original.turns)
        XCTAssertEqual(loaded.detectedLanguage, "por (100% confidence)")
    }

    // MARK: - Migrating after the rename

    /// The app was called Scribe Droplet. Anyone who ran that build has their
    /// library under the old folder, and would otherwise open a renamed app to
    /// an empty sidebar.
    func testTheLibraryMovesAcrossFromTheOldFolder() throws {
        let legacy = directory.appendingPathComponent("ScribeDroplet/Transcripts")
        let destination = directory.appendingPathComponent("RosyTranscribe/Transcripts")
        let old = TranscriptStore(directory: legacy)
        try old.save(record("Reunião", at: 1_700_000_000))

        XCTAssertTrue(TranscriptStore.migrateRenamedDirectory(from: legacy, to: destination))

        XCTAssertEqual(TranscriptStore(directory: destination).load().map(\.title), ["Reunião"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    /// It must never merge two libraries or overwrite newer transcripts with
    /// older ones, so an existing destination stops it dead.
    func testAnExistingLibraryIsNeverOverwritten() throws {
        let legacy = directory.appendingPathComponent("ScribeDroplet/Transcripts")
        let destination = directory.appendingPathComponent("RosyTranscribe/Transcripts")
        try TranscriptStore(directory: legacy).save(record("old", at: 1_000))
        try TranscriptStore(directory: destination).save(record("current", at: 2_000))

        XCTAssertFalse(TranscriptStore.migrateRenamedDirectory(from: legacy, to: destination))

        XCTAssertEqual(TranscriptStore(directory: destination).load().map(\.title), ["current"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path),
                      "the old folder is left alone rather than silently discarded")
    }

    func testNothingToMigrateIsNotAnError() {
        let legacy = directory.appendingPathComponent("ScribeDroplet/Transcripts")
        let destination = directory.appendingPathComponent("RosyTranscribe/Transcripts")
        XCTAssertFalse(TranscriptStore.migrateRenamedDirectory(from: legacy, to: destination))
    }

    /// A fresh install must not inherit anything, and must not crash looking.
    func testMigrationIsIdempotent() throws {
        let legacy = directory.appendingPathComponent("ScribeDroplet/Transcripts")
        let destination = directory.appendingPathComponent("RosyTranscribe/Transcripts")
        try TranscriptStore(directory: legacy).save(record("Reunião", at: 1_700_000_000))

        XCTAssertTrue(TranscriptStore.migrateRenamedDirectory(from: legacy, to: destination))
        XCTAssertFalse(TranscriptStore.migrateRenamedDirectory(from: legacy, to: destination))
        XCTAssertEqual(TranscriptStore(directory: destination).load().count, 1)
    }

    func testTheMigratedFolderKeepsItsPermissions() throws {
        let legacy = directory.appendingPathComponent("ScribeDroplet/Transcripts")
        let destination = directory.appendingPathComponent("RosyTranscribe/Transcripts")
        try TranscriptStore(directory: legacy).save(record("Reunião", at: 1_700_000_000))
        XCTAssertTrue(TranscriptStore.migrateRenamedDirectory(from: legacy, to: destination))

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value, 0o700)
    }

    /// Privileged legal material should not be world-readable.
    func testSavedTranscriptsAreReadableOnlyByTheirOwner() throws {
        let original = record("Reunião", at: 1_700_000_000)
        try store.save(original)

        let file = directory.appendingPathComponent("\(original.id.uuidString).json")
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.int16Value, 0o600)

        let dirMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(dirMode.int16Value, 0o700)
    }

    /// The files are meant to be openable in a text editor.
    func testSavedFilesArePlainReadableJSON() throws {
        let original = record("Reunião", at: 1_700_000_000)
        try store.save(original)
        let file = directory.appendingPathComponent("\(original.id.uuidString).json")
        let text = try String(contentsOf: file, encoding: .utf8)

        XCTAssertTrue(text.contains("\n"), "should be pretty printed")
        XCTAssertTrue(text.contains("Bom dia."))
    }
}
