import Foundation

/// One saved transcription.
///
/// Everything needed to redisplay a transcript exactly as it was left: the
/// grouped turns, plus the names and colours assigned to the speakers. The
/// audio is not kept — this app never opens it, and a library of meeting
/// recordings is a much bigger thing to look after than a library of text.
struct TranscriptRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var sourceFilename: String
    var detectedLanguage: String?
    var turns: [SpeakerTurn]
    var fallbackText: String
    var speakerNames: [String: String]
    var speakerColors: [String: SpeakerColor]
    /// Every speaker in this transcript, including any added by hand that own
    /// no segments yet. Optional so that records written before this existed
    /// still decode — the synthesised decoder uses `decodeIfPresent` for
    /// optional properties, and `TranscriptRecord.speakers` falls back to
    /// deriving the list from the turns.
    var speakerOrder: [String]?

    init(id: UUID = UUID(),
         title: String = "",
         createdAt: Date = Date(),
         sourceFilename: String = "",
         detectedLanguage: String? = nil,
         turns: [SpeakerTurn] = [],
         fallbackText: String = "",
         speakerNames: [String: String] = [:],
         speakerColors: [String: SpeakerColor] = [:],
         speakerOrder: [String]? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.sourceFilename = sourceFilename
        self.detectedLanguage = detectedLanguage
        self.turns = turns
        self.fallbackText = fallbackText
        self.speakerNames = speakerNames
        self.speakerColors = speakerColors
        self.speakerOrder = speakerOrder
    }

    /// The speaker list, derived from the turns when the record predates
    /// `speakerOrder` being stored.
    var speakers: [String] {
        if let speakerOrder, !speakerOrder.isEmpty { return speakerOrder }
        return TranscriptFormatter.speakerIDs(in: turns)
    }

    /// Never blank: an untitled transcript falls back to the file it came
    /// from, so the sidebar always has something to show.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let stem = (sourceFilename as NSString).deletingPathExtension
        return stem.isEmpty ? "Untitled" : stem
    }

    var hasContent: Bool {
        !turns.isEmpty || !fallbackText.isEmpty
    }

    /// A filename stem safe on every filesystem, for the Save panel.
    var suggestedFilename: String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = displayTitle
            .components(separatedBy: illegal)
            // Drop the empty pieces, or a title of "///" becomes "---".
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Transcript" : cleaned
    }
}

/// Reads and writes transcripts as one JSON file each.
///
/// One file per transcript rather than a single library file: a write only
/// ever risks the transcript being written, and a file that somehow becomes
/// unreadable costs one meeting rather than all of them.
struct TranscriptStore {

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        applicationSupport()
            .appendingPathComponent("RosyTranscribe", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    /// Where the library lived while the app was called Scribe Droplet.
    static func legacyDirectory() -> URL {
        applicationSupport()
            .appendingPathComponent("ScribeDroplet", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    private static func applicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// Moves the library across after the rename.
    ///
    /// Only when the destination does not exist yet, so it can never merge
    /// two libraries or overwrite newer transcripts with older ones. Failing
    /// is not fatal: the old folder simply stays where it is, and nothing is
    /// lost — which is why this reports rather than throws.
    @discardableResult
    static func migrateRenamedDirectory(from legacy: URL = legacyDirectory(),
                                        to destination: URL = defaultDirectory()) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path),
              !manager.fileExists(atPath: destination.path) else { return false }
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.moveItem(at: legacy, to: destination)
            return true
        } catch {
            return false
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Readable on purpose: these are the user's meetings, and being able
        // to open one in a text editor is worth the extra bytes.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Newest first. A file that cannot be read is skipped rather than
    /// throwing: one bad file must not cost the whole library.
    func load() -> [TranscriptRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                    return nil
                }
                return try? decoder.decode(TranscriptRecord.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ record: TranscriptRecord) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // createDirectory only applies attributes to directories it creates,
        // so tighten an existing one too.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let target = url(for: record.id)
        try encoder.encode(record).write(to: target, options: .atomic)

        // These are recordings of privileged meetings written out as plain
        // text. The default mode is world-readable, which is more exposure
        // than the content deserves on any shared machine.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    func delete(_ id: UUID) throws {
        let target = url(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }
}
