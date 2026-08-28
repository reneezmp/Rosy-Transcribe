import Foundation

/// Finding text in a transcript.
///
/// Pure: it reports *where* the matches are and knows nothing about colours or
/// scrolling, which keeps the matching rules testable on their own.
enum TranscriptSearch {

    struct Match: Equatable {
        let turnIndex: Int
        let range: Range<String.Index>
    }

    /// Case- and diacritic-insensitive.
    ///
    /// The diacritic part matters here: this transcribes Portuguese, and
    /// "averbacao" typed in a hurry has to find "averbação". Nobody wants to
    /// reach for the accent keys mid-search.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Every match, in reading order: by segment, then left to right.
    static func matches(for query: String, in turns: [SpeakerTurn]) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var found: [Match] = []
        for (index, turn) in turns.enumerated() {
            let text = turn.text
            var from = text.startIndex
            while from < text.endIndex,
                  let range = text.range(of: needle, options: options, range: from..<text.endIndex) {
                found.append(Match(turnIndex: index, range: range))
                // A zero-width result would loop forever; step past it.
                from = range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound
            }
        }
        return found
    }

    /// Matches grouped by segment, which is how the rows want them.
    static func rangesByTurn(_ matches: [Match]) -> [Int: [Range<String.Index>]] {
        var grouped: [Int: [Range<String.Index>]] = [:]
        for match in matches {
            grouped[match.turnIndex, default: []].append(match.range)
        }
        return grouped
    }
}
