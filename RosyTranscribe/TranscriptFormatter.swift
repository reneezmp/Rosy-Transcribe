import Foundation

/// One spoken word and its location in the source audio.
///
/// Optional timestamps tolerate incomplete API responses. Keeping the word
/// itself beside them leaves enough information for word-level seeking later,
/// even though the first playback UI only seeks to the start of a segment.
struct TimedWord: Equatable, Codable {
    let text: String
    let start: Double?
    let end: Double?
}

/// One run of consecutive words spoken by the same speaker.
struct SpeakerTurn: Equatable, Codable {
    /// The raw API id, e.g. "speaker_0". Nil when diarization returned nothing.
    /// Mutable because a segment can be reassigned to another speaker.
    var speakerID: String?
    /// Mutable because the transcript is editable: Scribe mishears things,
    /// and a legal transcript has to be correctable.
    var text: String
    /// Optional so transcripts written before playback support still decode.
    var timedWords: [TimedWord]?

    init(speakerID: String?, text: String, timedWords: [TimedWord]? = nil) {
        self.speakerID = speakerID
        self.text = text
        self.timedWords = timedWords
    }

    var startTime: Double? {
        timedWords?.compactMap(\.start).first
    }

    /// Timestamp for an Option-click in the displayed text. Once a segment
    /// has been edited away from the API's original words, exact word mapping
    /// is no longer trustworthy, so it honestly falls back to the segment.
    func timestamp(atUTF16Offset offset: Int) -> Double? {
        guard let timedWords, !timedWords.isEmpty else { return startTime }
        guard timedWords.map(\.text).joined(separator: " ") == text else { return startTime }

        var cursor = 0
        for word in timedWords {
            let end = cursor + word.text.utf16.count
            if offset >= cursor && offset <= end { return word.start ?? startTime }
            cursor = end + 1
        }
        return startTime
    }
}

/// Turns `words[]` into a speaker-labelled transcript.
///
/// Deliberately free of UI and networking types: this is a pure function from
/// an array of words to a string, which makes it the one piece of the app that
/// can be tested without touching the API.
enum TranscriptFormatter {

    /// Groups consecutive words by `speaker_id`.
    ///
    /// Only entries of type "word" are considered. The API also emits
    /// "spacing" and "audio_event" entries, and including them produces a
    /// transcript full of stray whitespace tokens and bracketed noises.
    static func turns(from words: [TranscriptionWord]) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        var speaker: String?
        var tokens: [String] = []
        var timedWords: [TimedWord] = []

        for word in words where isSpokenWord(word) {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if !tokens.isEmpty && word.speakerId != speaker {
                turns.append(SpeakerTurn(speakerID: speaker,
                                         text: tokens.joined(separator: " "),
                                         timedWords: storedTimings(timedWords)))
                tokens = []
                timedWords = []
            }
            if tokens.isEmpty {
                speaker = word.speakerId
            }
            tokens.append(token)
            timedWords.append(TimedWord(text: token, start: word.start, end: word.end))
        }

        if !tokens.isEmpty {
            turns.append(SpeakerTurn(speakerID: speaker,
                                     text: tokens.joined(separator: " "),
                                     timedWords: storedTimings(timedWords)))
        }
        return turns
    }

    /// Renders grouped turns as the display transcript, using whatever names
    /// have been assigned.
    ///
    /// Falls back to the flat `text` field when there is nothing to group —
    /// an empty `words[]`, or a response with no speech in it. A transcript
    /// without speaker labels is still worth showing.
    static func format(turns: [SpeakerTurn],
                       names: [String: String],
                       fallbackText: String) -> String {
        guard !turns.isEmpty else {
            return fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return merged(turns)
            .map { "\(displayName(for: $0.speakerID, names: names)):\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Joins adjacent turns by the same speaker.
    ///
    /// Only ever applied on the way out. Two adjacent turns by one speaker can
    /// only arise from a reassignment, and keeping them separate in the data
    /// is what makes that reassignment reversible — but the reader should see
    /// one block of speech, not the same name twice in a row.
    static func merged(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var out: [SpeakerTurn] = []
        for turn in turns {
            if let last = out.last, last.speakerID == turn.speakerID {
                let combinedTimings: [TimedWord]?
                switch (last.timedWords, turn.timedWords) {
                case let (left?, right?): combinedTimings = left + right
                case let (left?, nil): combinedTimings = left
                case let (nil, right?): combinedTimings = right
                case (nil, nil): combinedTimings = nil
                }
                out[out.count - 1] = SpeakerTurn(speakerID: last.speakerID,
                                                 text: last.text + " " + turn.text,
                                                 timedWords: combinedTimings)
            } else {
                out.append(turn)
            }
        }
        return out
    }

    /// Convenience for the unnamed case.
    static func format(words: [TranscriptionWord]?, fallbackText: String) -> String {
        format(turns: turns(from: words ?? []), names: [:], fallbackText: fallbackText)
    }

    /// The same transcript as Markdown, for saving to a file.
    ///
    /// Speakers become bold lines rather than "Name:" lines, which is what
    /// renders sensibly in a Markdown viewer. The title becomes the H1 and is
    /// omitted entirely when blank, rather than leaving an empty heading.
    static func markdown(title: String,
                         turns: [SpeakerTurn],
                         names: [String: String],
                         fallbackText: String) -> String {
        var out = ""
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heading.isEmpty {
            out += "# \(heading)\n\n"
        }
        guard !turns.isEmpty else {
            let flat = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.isEmpty ? out : out + flat + "\n"
        }
        out += merged(turns)
            .map { "**\(displayName(for: $0.speakerID, names: names))**\n\($0.text)" }
            .joined(separator: "\n\n")
        return out + "\n"
    }

    /// The name to show for a speaker: the assigned one where there is one,
    /// otherwise the API's position turned into "Speaker N". A name that is
    /// blank or only whitespace counts as unassigned, so clearing the field
    /// returns the speaker to its default rather than leaving a nameless row.
    static func displayName(for speakerID: String?, names: [String: String]) -> String {
        if let speakerID,
           let assigned = names[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !assigned.isEmpty {
            return assigned
        }
        return label(for: speakerID)
    }

    /// "speaker_0" -> "Speaker 1". The API is zero-indexed; humans are not.
    /// Any id that does not match that shape is shown unchanged rather than
    /// mangled, so a future API change degrades visibly instead of silently.
    static func label(for speakerID: String?) -> String {
        // No speaker means either diarization found none, or the speaker they
        // belonged to was deleted. "Unknown" is honest about both.
        guard let speakerID, !speakerID.isEmpty else { return "Unknown" }
        let prefix = "speaker_"
        if speakerID.hasPrefix(prefix), let index = Int(speakerID.dropFirst(prefix.count)) {
            return "Speaker \(index + 1)"
        }
        return speakerID
    }

    /// The distinct speakers found, in order of first appearance.
    static func speakerIDs(in words: [TranscriptionWord]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for word in words where isSpokenWord(word) {
            guard let id = word.speakerId, !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    /// The single character shown in a speaker's badge.
    ///
    /// A named speaker gets their first letter. An unnamed one gets their
    /// number, because "S" for every "Speaker N" would tell you nothing.
    static func initial(for speakerID: String?, names: [String: String]) -> String {
        if let speakerID,
           let assigned = names[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let first = assigned.first {
            return String(first).uppercased()
        }
        let prefix = "speaker_"
        if let speakerID, speakerID.hasPrefix(prefix),
           let index = Int(speakerID.dropFirst(prefix.count)) {
            return String(index + 1)
        }
        return "?"
    }

    /// The distinct speakers in a set of turns, in order of first appearance.
    /// This is the order the People panel lists them in, and the order colours
    /// are handed out in.
    static func speakerIDs(in turns: [SpeakerTurn]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for turn in turns {
            guard let id = turn.speakerID, !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    /// A missing `type` is treated as speech. Spacing and audio-event entries
    /// always carry an explicit type, so this only matters if the API stops
    /// sending the field — in which case dropping every word would be worse.
    private static func isSpokenWord(_ word: TranscriptionWord) -> Bool {
        word.type == nil || word.type == "word"
    }

    /// A response with no timestamps behaves like an old transcript rather
    /// than acquiring a meaningless array of nil timing values.
    private static func storedTimings(_ words: [TimedWord]) -> [TimedWord]? {
        words.contains { $0.start != nil || $0.end != nil } ? words : nil
    }
}
