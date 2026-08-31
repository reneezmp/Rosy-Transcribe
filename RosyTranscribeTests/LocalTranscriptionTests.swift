import XCTest

final class LocalTranscriptionTests: XCTestCase {
    func testSpeakerTimelineIsAppliedToRecognizedWords() {
        let words = [
            TranscriptionWord(type: "word", text: "Bom", start: 0.2, end: 0.5, speakerId: nil),
            TranscriptionWord(type: "word", text: "dia", start: 1.2, end: 1.5, speakerId: nil),
            TranscriptionWord(type: "word", text: "Rosy", start: 2.2, end: 2.5, speakerId: nil),
        ]
        let segments = [
            LocalSpeakerSegment(id: "fluid-7", start: 0, end: 1),
            LocalSpeakerSegment(id: "fluid-2", start: 1, end: 2),
            LocalSpeakerSegment(id: "fluid-7", start: 2, end: 3),
        ]

        let assigned = LocalTranscriptionService.assignSpeakers(to: words, from: segments)

        XCTAssertEqual(assigned.map(\.speakerId), ["speaker_0", "speaker_1", "speaker_0"])
    }

    func testOverlappingSegmentWithMostCoverageWins() {
        let word = TranscriptionWord(type: "word", text: "sim", start: 4, end: 5, speakerId: nil)
        let segments = [
            LocalSpeakerSegment(id: "A", start: 3.9, end: 4.2),
            LocalSpeakerSegment(id: "B", start: 4.1, end: 5.1),
        ]

        let assigned = LocalTranscriptionService.assignSpeakers(to: [word], from: segments)

        XCTAssertEqual(assigned.first?.speakerId, "speaker_1")
    }

    func testAWordInALargeDiarizationGapStaysUnknown() {
        let word = TranscriptionWord(type: "word", text: "incerto", start: 5, end: 5.2, speakerId: nil)
        let segments = [LocalSpeakerSegment(id: "A", start: 0, end: 1)]

        let assigned = LocalTranscriptionService.assignSpeakers(to: [word], from: segments)

        XCTAssertNil(assigned.first?.speakerId)
    }

    func testATinyUnambiguousBoundaryGapUsesTheNearestSpeaker() {
        let word = TranscriptionWord(type: "word", text: "sim", start: 1.1, end: 1.2, speakerId: nil)
        let segments = [LocalSpeakerSegment(id: "A", start: 0, end: 1)]

        let assigned = LocalTranscriptionService.assignSpeakers(to: [word], from: segments)

        XCTAssertEqual(assigned.first?.speakerId, "speaker_0")
    }

    func testAnEquidistantGapBetweenSpeakersStaysUnknown() {
        let word = TranscriptionWord(type: "word", text: "hum", start: 1.45, end: 1.55, speakerId: nil)
        let segments = [
            LocalSpeakerSegment(id: "A", start: 0, end: 1.4),
            LocalSpeakerSegment(id: "B", start: 1.6, end: 2),
        ]

        let assigned = LocalTranscriptionService.assignSpeakers(to: [word], from: segments)

        XCTAssertNil(assigned.first?.speakerId)
    }

    func testExpectedSpeakerCountMergesClosestDuplicateVoices() {
        let segments = [
            LocalSpeakerSegment(id: "A", start: 0, end: 2, embedding: [1, 0]),
            LocalSpeakerSegment(id: "A2", start: 2, end: 3, embedding: [0.99, 0.01]),
            LocalSpeakerSegment(id: "B", start: 3, end: 5, embedding: [0, 1]),
        ]

        let merged = LocalTranscriptionService.consolidate(segments, maximumSpeakers: 2)

        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
        XCTAssertEqual(merged[0].id, merged[1].id)
        XCTAssertNotEqual(merged[1].id, merged[2].id)
    }

    func testExpectedSpeakerCountNeverInventsMissingVoices() {
        let segments = [
            LocalSpeakerSegment(id: "A", start: 0, end: 1, embedding: [1, 0]),
            LocalSpeakerSegment(id: "B", start: 1, end: 2, embedding: [0, 1]),
        ]

        let unchanged = LocalTranscriptionService.consolidate(segments, maximumSpeakers: 4)

        XCTAssertEqual(Set(unchanged.map(\.id)), ["A", "B"])
    }
}
