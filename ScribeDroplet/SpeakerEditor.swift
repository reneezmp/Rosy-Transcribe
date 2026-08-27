import Foundation

/// Edits to who said what, as pure functions over an array of turns.
///
/// Reassignment never merges or deletes a turn. Two adjacent turns by the same
/// speaker are joined only when the transcript is rendered, so every edit stays
/// reversible: physically merging a reassigned segment into its neighbours
/// would destroy the boundary and make putting it back impossible.
enum SpeakerEditor {

    /// Moves one segment to another speaker.
    static func assigning(_ turns: [SpeakerTurn],
                          at index: Int,
                          to speakerID: String) -> [SpeakerTurn] {
        guard turns.indices.contains(index) else { return turns }
        var edited = turns
        edited[index].speakerID = speakerID
        return edited
    }

    /// Moves every segment belonging to one speaker to another — the fix for
    /// diarization splitting one person into two.
    static func reassigningAll(_ turns: [SpeakerTurn],
                               from source: String?,
                               to destination: String) -> [SpeakerTurn] {
        turns.map { turn in
            guard turn.speakerID == source else { return turn }
            return SpeakerTurn(speakerID: destination, text: turn.text)
        }
    }

    /// The lowest `speaker_N` not already taken.
    ///
    /// Added speakers follow the API's own naming, so a manually added third
    /// person is "Speaker 3" without any special casing in the label logic.
    static func nextSpeakerID(notIn existing: [String]) -> String {
        let taken = Set(existing)
        var index = 0
        while taken.contains("speaker_\(index)") {
            index += 1
        }
        return "speaker_\(index)"
    }

    /// How many segments a speaker currently owns. A speaker with none can be
    /// removed safely; one with segments cannot, or they would be orphaned.
    static func segmentCount(for speakerID: String, in turns: [SpeakerTurn]) -> Int {
        turns.filter { $0.speakerID == speakerID }.count
    }
}
