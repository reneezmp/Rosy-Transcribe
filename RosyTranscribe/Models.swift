import Foundation

// Codable mirrors of the ElevenLabs POST /v1/speech-to-text response.
//
// Field names are spelled out in CodingKeys rather than relying on a
// key-decoding strategy, so this file doubles as documentation of the wire
// format. Everything except `text` is optional: the API is allowed to grow,
// and a missing field should never cost the user a completed transcription.

struct TranscriptionResponse: Decodable {
    /// The flat transcript, with no speaker information.
    let text: String
    /// The language the model detected, e.g. "por".
    let languageCode: String?
    /// Confidence in `languageCode`, 0...1.
    let languageProbability: Double?
    /// Length of the submitted audio, in seconds.
    let audioDurationSecs: Double?
    /// Present when `timestamps_granularity` was requested.
    let words: [TranscriptionWord]?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
        case languageProbability = "language_probability"
        case audioDurationSecs = "audio_duration_secs"
        case words
    }

    init(text: String, languageCode: String?, languageProbability: Double?,
         audioDurationSecs: Double?, words: [TranscriptionWord]?) {
        self.text = text
        self.languageCode = languageCode
        self.languageProbability = languageProbability
        self.audioDurationSecs = audioDurationSecs
        self.words = words
    }
}

struct TranscriptionWord: Decodable {
    /// "word", "spacing" or "audio_event". Only "word" carries speech.
    let type: String?
    let text: String
    let start: Double?
    let end: Double?
    /// "speaker_0", "speaker_1", ... assigned in order of first appearance.
    /// Absent when `diarize` was false.
    let speakerId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case start
        case end
        case speakerId = "speaker_id"
    }


    init(type: String?, text: String, start: Double?, end: Double?, speakerId: String?) {
        self.type = type
        self.text = text
        self.start = start
        self.end = end
        self.speakerId = speakerId
    }
}
