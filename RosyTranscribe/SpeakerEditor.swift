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

    /// Replaces one segment's text, as it is typed.
    static func replacingText(_ turns: [SpeakerTurn],
                              at index: Int,
                              with text: String) -> [SpeakerTurn] {
        guard turns.indices.contains(index) else { return turns }
        var edited = turns
        edited[index].text = text
        return edited
    }

    /// Tidies one segment once editing finishes: surrounding whitespace goes,
    /// and a segment emptied entirely is removed rather than left as a blank
    /// row that would export as a speaker name with nothing under it.
    static func committingText(_ turns: [SpeakerTurn], at index: Int) -> [SpeakerTurn] {
        guard turns.indices.contains(index) else { return turns }
        var edited = turns
        let trimmed = edited[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            edited.remove(at: index)
        } else {
            edited[index].text = trimmed
        }
        return edited
    }

    /// Detaches every segment belonging to a speaker, leaving them unowned
    /// and therefore shown as "Unknown". Deleting a speaker must never delete
    /// what they said.
    static func unassigning(_ turns: [SpeakerTurn], speakerID: String) -> [SpeakerTurn] {
        turns.map { turn in
            guard turn.speakerID == speakerID else { return turn }
            return SpeakerTurn(speakerID: nil, text: turn.text)
        }
    }

    /// How many segments a speaker currently owns. A speaker with none can be
    /// removed safely; one with segments cannot, or they would be orphaned.
    static func segmentCount(for speakerID: String, in turns: [SpeakerTurn]) -> Int {
        turns.filter { $0.speakerID == speakerID }.count
    }
}
