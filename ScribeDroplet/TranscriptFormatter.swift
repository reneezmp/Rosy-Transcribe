import Foundation

/// One run of consecutive words spoken by the same speaker.
struct SpeakerTurn: Equatable, Codable {
    /// The raw API id, e.g. "speaker_0". Nil when diarization returned nothing.
    let speakerID: String?
    let text: String
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

        for word in words where isSpokenWord(word) {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if !tokens.isEmpty && word.speakerId != speaker {
                turns.append(SpeakerTurn(speakerID: speaker, text: tokens.joined(separator: " ")))
                tokens = []
            }
            if tokens.isEmpty {
                speaker = word.speakerId
            }
            tokens.append(token)
        }

        if !tokens.isEmpty {
            turns.append(SpeakerTurn(speakerID: speaker, text: tokens.joined(separator: " ")))
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
        return turns
            .map { "\(displayName(for: $0.speakerID, names: names)):\n\($0.text)" }
            .joined(separator: "\n\n")
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
        out += turns
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
        guard let speakerID, !speakerID.isEmpty else { return "Speaker" }
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
}
