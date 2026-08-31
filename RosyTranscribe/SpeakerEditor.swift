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
            return SpeakerTurn(speakerID: destination, text: turn.text, timedWords: turn.timedWords)
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

    /// Breaks one segment at a UTF-16 caret offset. Both halves inherit the
    /// same speaker so the new boundary is immediately useful for isolating a
    /// sentence and then reassigning only that sentence to somebody else.
    /// Empty halves are refused: Return at the start or end is not a split.
    static func splitting(_ turns: [SpeakerTurn],
                          at index: Int,
                          utf16Offset: Int) -> [SpeakerTurn] {
        guard turns.indices.contains(index) else { return turns }
        let turn = turns[index]
        guard utf16Offset > 0, utf16Offset < turn.text.utf16.count,
              let utf16Index = turn.text.utf16.index(
                turn.text.utf16.startIndex,
                offsetBy: utf16Offset,
                limitedBy: turn.text.utf16.endIndex),
              let splitIndex = String.Index(utf16Index, within: turn.text) else { return turns }

        let left = String(turn.text[..<splitIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(turn.text[splitIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return turns }

        let timings = splitTimings(turn.timedWords, left: left, right: right)
        var edited = turns
        edited.replaceSubrange(index...index, with: [
            SpeakerTurn(speakerID: turn.speakerID, text: left, timedWords: timings.left),
            SpeakerTurn(speakerID: turn.speakerID, text: right, timedWords: timings.right),
        ])
        return edited
    }

    /// Keeps exact word seeking when the caret landed on an original word
    /// boundary. If edits have made the mapping ambiguous, discard the stale
    /// word map rather than attaching incorrect timestamps to new text.
    private static func splitTimings(_ words: [TimedWord]?,
                                     left: String,
                                     right: String) -> (left: [TimedWord]?, right: [TimedWord]?) {
        guard let words else { return (nil, nil) }
        for boundary in 1..<words.count {
            let first = Array(words[..<boundary])
            let second = Array(words[boundary...])
            if first.map(\.text).joined(separator: " ") == left,
               second.map(\.text).joined(separator: " ") == right {
                return (first, second)
            }
        }
        return (nil, nil)
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
            return SpeakerTurn(speakerID: nil, text: turn.text, timedWords: turn.timedWords)
        }
    }

    /// How many segments a speaker currently owns. A speaker with none can be
    /// removed safely; one with segments cannot, or they would be orphaned.
    static func segmentCount(for speakerID: String, in turns: [SpeakerTurn]) -> Int {
        turns.filter { $0.speakerID == speakerID }.count
    }
}
