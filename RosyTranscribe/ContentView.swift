import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - View model

/// All state and all work. Marked `@MainActor`, so every published property is
/// mutated on the main thread; the actual networking happens inside
/// `URLSession`, which is off the main thread by construction.
@MainActor
final class TranscriberModel: ObservableObject {

    private enum DefaultsKey {
        static let language = "transcriptionLanguage"
        static let keyterms = "keyterms"
        static let engine = "transcriptionEngine"
        static let expectedSpeakers = "expectedSpeakers"
    }

    // MARK: Settings

    /// Lives in the Keychain, not UserDefaults. Written on every edit — a
    /// Keychain write of a fifty-byte item is far too cheap to be worth
    /// debouncing, and this way a key typed and never used is still saved.
    @Published var apiKey: String = "" {
        didSet { persistAPIKey() }
    }

    @Published var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: DefaultsKey.language) }
    }

    @Published var engine: TranscriptionEngine {
        didSet { defaults.set(engine.rawValue, forKey: DefaultsKey.engine) }
    }

    /// Zero means automatic. A known headcount adjusts the local clustering
    /// sensitivity; it is irrelevant to ElevenLabs and hidden there.
    @Published var expectedSpeakers: Int {
        didSet { defaults.set(expectedSpeakers, forKey: DefaultsKey.expectedSpeakers) }
    }

    /// Free text: commas or newlines between terms. Not a secret, so plain
    /// UserDefaults is the right home for it.
    @Published var keytermsText: String {
        didSet { defaults.set(keytermsText, forKey: DefaultsKey.keyterms) }
    }

    // MARK: The transcript being worked on

    @Published var title: String = "" {
        didSet { scheduleSave() }
    }
    @Published var selectedFile: URL?
    @Published var selectedFileSize: Int64?
    @Published var sourceFilename: String = ""
    /// Only the path is retained. The recording remains entirely under the
    /// user's control and may normally disappear after the meeting.
    @Published var audioPath: String? {
        didSet { scheduleSave() }
    }
    @Published var secondaryAudioPath: String? {
        didSet { scheduleSave() }
    }
    @Published var recordingMode: RecordingMode? {
        didSet { scheduleSave() }
    }
    @Published var turns: [SpeakerTurn] = [] {
        didSet {
            scheduleSave()
            refreshMatches()
        }
    }
    /// The flat transcript, shown when diarization produced nothing to group.
    @Published var fallbackText: String = ""
    @Published var detectedLanguage: String?
    @Published var errorMessage: String?
    @Published var isTranscribing: Bool = false
    @Published var keychainWarning: String?
    @Published var storeWarning: String?

    /// Names and colours assigned to `speaker_0`, `speaker_1`, …
    ///
    /// Saved with the transcript, but never carried to the next one: the API
    /// assigns speaker ids by order of first appearance, so `speaker_0` is a
    /// different person in every recording.
    @Published var speakerNames: [String: String] = [:] {
        didSet { scheduleSave() }
    }
    @Published var speakerColors: [String: SpeakerColor] = [:] {
        didSet { scheduleSave() }
    }
    /// Every speaker in this transcript, in order of first appearance, plus
    /// any added by hand. Held explicitly rather than derived from the turns,
    /// because an added speaker owns no segments until one is assigned.
    @Published var speakerOrder: [String] = [] {
        didSet { scheduleSave() }
    }

    // MARK: The library

    /// Search lives here rather than in the view so the transcript is scanned
    /// when the query or the text actually changes, not once per redraw for
    /// every place in `body` that asks how many matches there are.
    @Published var searchQuery: String = "" {
        didSet { refreshMatches() }
    }
    @Published private(set) var matches: [TranscriptSearch.Match] = []
    @Published var currentMatch = 0

    @Published private(set) var records: [TranscriptRecord] = []
    @Published private(set) var currentRecordID: UUID?

    private var currentCreatedAt = Date()
    /// Suppresses autosave while a record is being loaded into the editor —
    /// otherwise opening a transcript immediately writes it back.
    private var isLoadingRecord = false
    private var saveTask: Task<Void, Never>?

    private let defaults: UserDefaults
    private let store: TranscriptStore
    private let service = TranscriptionService()
    private let localService = LocalTranscriptionService()
    let playback = AudioPlaybackService()
    private var playbackCancellable: AnyCancellable?

    init(defaults: UserDefaults = .standard, store: TranscriptStore = TranscriptStore()) {
        self.defaults = defaults
        self.store = store
        self.language = TranscriptionLanguage(rawValue: defaults.string(forKey: DefaultsKey.language) ?? "")
            ?? .portuguese
        let storedEngine = TranscriptionEngine(rawValue: defaults.string(forKey: DefaultsKey.engine) ?? "")
            ?? .elevenLabs
        self.engine = storedEngine == .onDevice && !LocalTranscriptionAvailability.isAvailable
            ? .elevenLabs : storedEngine
        let storedSpeakerCount = defaults.integer(forKey: DefaultsKey.expectedSpeakers)
        self.expectedSpeakers = (2...8).contains(storedSpeakerCount) ? storedSpeakerCount : 0
        self.keytermsText = defaults.string(forKey: DefaultsKey.keyterms) ?? ""
        self.audioPath = nil
        self.secondaryAudioPath = nil
        self.recordingMode = nil
        TranscriptStore.migrateRenamedDirectory()
        self.records = store.load()

        // Both migrations run before anything reads either location. The
        // rename one first: it is the app inheriting from its own former
        // name, and the UserDefaults one should see the result.
        KeychainStore.migrateRenamedServiceIfNeeded()
        KeychainStore.migrateLegacyKeyIfNeeded(defaults: defaults)
        do {
            self.apiKey = try KeychainStore.read() ?? ""
        } catch {
            self.apiKey = ""
            self.keychainWarning = error.localizedDescription
        }

        // Forward player ticks through the model so views observing this
        // model redraw while the playhead moves.
        self.playbackCancellable = playback.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: Derived state

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canTranscribe: Bool {
        guard selectedFile != nil, !isTranscribing else { return false }
        switch engine {
        case .elevenLabs: return hasAPIKey && keytermsProblem == nil
        case .onDevice: return LocalTranscriptionAvailability.isAvailable
        }
    }

    var hasTranscript: Bool {
        !turns.isEmpty || !fallbackText.isEmpty
    }

    var linkedAudioURL: URL? {
        guard let audioPath, !audioPath.isEmpty else { return nil }
        return URL(fileURLWithPath: audioPath)
    }

    var linkedAudioURLs: [URL] {
        [audioPath, secondaryAudioPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .map(URL.init(fileURLWithPath:))
    }

    var isAudioAvailable: Bool {
        !linkedAudioURLs.isEmpty && linkedAudioURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// The transcript as plain text, for the pasteboard.
    var transcriptText: String {
        TranscriptFormatter.format(turns: turns, names: speakerNames, fallbackText: fallbackText)
    }

    /// The transcript as Markdown, for saving to a file.
    var markdownText: String {
        TranscriptFormatter.markdown(title: title,
                                     turns: turns,
                                     names: speakerNames,
                                     fallbackText: fallbackText)
    }

    func displayName(for speakerID: String?) -> String {
        TranscriptFormatter.displayName(for: speakerID, names: speakerNames)
    }

    func color(for speakerID: String?) -> SpeakerColor {
        guard let speakerID, let color = speakerColors[speakerID] else { return .blue }
        return color
    }

    /// Parsed live so the count and any problem show up while typing, rather
    /// than as a surprise when the Transcribe button is pressed.
    var keyterms: [String] {
        Keyterms.parse(keytermsText)
    }

    var keytermsProblem: String? {
        do {
            try Keyterms.validate(keyterms)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var keytermsSummary: String {
        let count = keyterms.count
        switch count {
        case 0: return "No key terms. Names and uncommon vocabulary go here."
        case 1: return "1 key term of \(Keyterms.maxCount)."
        default: return "\(count) key terms of \(Keyterms.maxCount)."
        }
    }

    // MARK: Choosing a file

    func selectFile(_ url: URL) {
        guard isAcceptableFile(url) else {
            errorMessage = "\(url.lastPathComponent) does not look like an audio or video file. Supported: \(Self.supportedExtensionList)."
            return
        }
        selectedFile = url
        selectedFileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))
            .flatMap { $0.fileSize }
            .map { Int64($0) }
        errorMessage = nil

        // A dropped file is the start of a new transcript, not an edit of the
        // one on screen.
        beginNewRecord()
        audioPath = url.path
        preparePlayback()
        // Seed the title from the filename, but never overwrite one already
        // typed.
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose an audio file to transcribe"
        panel.allowedContentTypes = Self.allowedContentTypes
        if panel.runModal() == .OK, let url = panel.url {
            selectFile(url)
        }
    }

    /// Makes a Rosy-created recording the source for a new transcript. A
    /// meeting retains both paths; ordinary recordings retain one.
    func selectRecording(_ recording: RecordedAudio) {
        guard let primary = recording.primaryURL else { return }
        beginNewRecord()
        selectedFile = primary
        selectedFileSize = (try? primary.resourceValues(forKeys: [.fileSizeKey]))
            .flatMap { $0.fileSize }
            .map(Int64.init)
        sourceFilename = primary.lastPathComponent
        audioPath = primary.path
        if recording.mode == .meeting {
            secondaryAudioPath = recording.microphoneURL?.path
        }
        recordingMode = recording.mode
        title = recording.title
        errorMessage = nil
        preparePlayback()
    }

    // MARK: Transcribing

    func transcribe() async {
        guard let fileURL = selectedFile else { return }

        isTranscribing = true
        errorMessage = nil
        clearTranscript()
        defer { isTranscribing = false }

        do {
            let response: TranscriptionResponse
            var microphoneResponse: TranscriptionResponse?
            let microphoneURL = secondaryAudioPath.map(URL.init(fileURLWithPath:))
            let isMicrophoneOnly = recordingMode == .microphone
            switch engine {
            case .elevenLabs:
                let terms = try Keyterms.validated(keytermsText)
                let request = TranscriptionRequest(fileURL: fileURL,
                                                   apiKey: apiKey,
                                                   languageCode: language.languageCode,
                                                   keyterms: terms,
                                                   diarize: !isMicrophoneOnly)
                if let microphoneURL {
                    async let primary = service.transcribe(request)
                    async let microphone = service.transcribe(
                        TranscriptionRequest(fileURL: microphoneURL,
                                             apiKey: apiKey,
                                             languageCode: language.languageCode,
                                             keyterms: terms,
                                             diarize: false)
                    )
                    (response, microphoneResponse) = try await (primary, microphone)
                } else {
                    response = try await service.transcribe(request)
                }
            case .onDevice:
                response = try await localService.transcribe(
                    fileURL: fileURL,
                    language: language,
                    expectedSpeakers: expectedSpeakers == 0 ? nil : expectedSpeakers
                )
                // Run sequentially locally: two simultaneous SpeechAnalyzer +
                // diariser pipelines needlessly double peak memory.
                if let microphoneURL {
                    microphoneResponse = try await localService.transcribe(
                        fileURL: microphoneURL,
                        language: language,
                        expectedSpeakers: nil
                    )
                }
            }

            isLoadingRecord = true
            var words = response.words ?? []
            if isMicrophoneOnly {
                words = Self.forcingSpeaker("speaker_local", in: words)
            }
            if let microphoneResponse {
                words += Self.forcingSpeaker("speaker_local", in: microphoneResponse.words ?? [])
                words.sort { ($0.start ?? .greatestFiniteMagnitude) < ($1.start ?? .greatestFiniteMagnitude) }
            }
            turns = TranscriptFormatter.turns(from: words)
            if let microphoneResponse, words.isEmpty {
                fallbackText = "Others:\n\(response.text)\n\nYou:\n\(microphoneResponse.text)"
            } else {
                fallbackText = response.text
            }
            speakerOrder = TranscriptFormatter.speakerIDs(in: turns)
            speakerColors = SpeakerColor.assign(to: speakerOrder)
            if speakerOrder.contains("speaker_local") {
                speakerNames["speaker_local"] = "You"
            }
            detectedLanguage = Self.describeLanguage(response)
            sourceFilename = fileURL.lastPathComponent
            isLoadingRecord = false

            if hasTranscript {
                // Saved straight away rather than on a timer: a transcription
                // costs money and minutes, and must survive a crash.
                saveCurrentRecord()
            } else {
                errorMessage = "The transcription came back empty. There may be no speech in that file."
            }
        } catch {
            // localizedDescription carries the actionable text for both
            // TranscriptionError and KeytermsError.
            errorMessage = error.localizedDescription
        }
    }

    private static func forcingSpeaker(_ speakerID: String,
                                       in words: [TranscriptionWord]) -> [TranscriptionWord] {
        words.map {
            TranscriptionWord(type: $0.type,
                              text: $0.text,
                              start: $0.start,
                              end: $0.end,
                              speakerId: speakerID)
        }
    }

    // MARK: The library

    func open(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        saveTask?.cancel()
        isLoadingRecord = true
        currentRecordID = record.id
        currentCreatedAt = record.createdAt
        title = record.title
        sourceFilename = record.sourceFilename
        audioPath = record.audioPath
        secondaryAudioPath = record.secondaryAudioPath
        recordingMode = record.recordingMode
        detectedLanguage = record.detectedLanguage
        turns = record.turns
        fallbackText = record.fallbackText
        speakerNames = record.speakerNames
        speakerColors = record.speakerColors
        speakerOrder = record.speakers
        selectedFile = nil
        selectedFileSize = nil
        errorMessage = nil
        isLoadingRecord = false
        preparePlayback()
    }

    func newTranscription() {
        saveTask?.cancel()
        isLoadingRecord = true
        beginNewRecord()
        title = ""
        selectedFile = nil
        selectedFileSize = nil
        errorMessage = nil
        isLoadingRecord = false
    }

    func delete(_ id: UUID) {
        do {
            try store.delete(id)
            records.removeAll { $0.id == id }
            if currentRecordID == id { newTranscription() }
            storeWarning = nil
        } catch {
            storeWarning = "Could not delete that transcript: \(error.localizedDescription)"
        }
    }

    func saveCurrentRecord() {
        guard hasTranscript else { return }
        let id = currentRecordID ?? UUID()
        currentRecordID = id
        let record = snapshot(id: id)
        do {
            try store.save(record)
            upsert(record)
            storeWarning = nil
        } catch {
            storeWarning = "Could not save this transcript: \(error.localizedDescription)"
        }
    }

    // MARK: Editing speakers

    func assign(turnAt index: Int, to speakerID: String) {
        turns = SpeakerEditor.assigning(turns, at: index, to: speakerID)
    }

    func reassignAll(from source: String?, to destination: String) {
        turns = SpeakerEditor.reassigningAll(turns, from: source, to: destination)
    }

    // MARK: Editing the text

    func textBinding(at index: Int) -> Binding<String> {
        Binding(get: { self.turns.indices.contains(index) ? self.turns[index].text : "" },
                set: { self.turns = SpeakerEditor.replacingText(self.turns, at: index, with: $0) })
    }

    func splitTurn(at index: Int, utf16Offset: Int) {
        turns = SpeakerEditor.splitting(turns, at: index, utf16Offset: utf16Offset)
    }

    /// Returns true when the segment was emptied and therefore removed.
    @discardableResult
    func commitEdit(at index: Int) -> Bool {
        let before = turns.count
        turns = SpeakerEditor.committingText(turns, at: index)
        let removed = turns.count < before

        // Deleting the last remaining segment must not bring the transcript
        // back. `format` falls back to the flat API text when there are no
        // turns, so leaving it in place would silently undo the deletion and
        // then save it that way.
        if removed && turns.isEmpty {
            fallbackText = ""
        }
        return removed
    }

    // MARK: Search

    private func refreshMatches() {
        matches = TranscriptSearch.matches(for: searchQuery, in: turns)
        currentMatch = 0
    }

    /// Kept in range: the transcript can be edited while a search is open, and
    /// matches can vanish from underneath the current position.
    var clampedMatch: Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(currentMatch, 0), matches.count - 1)
    }

    func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = (clampedMatch + delta + matches.count) % matches.count
    }

    func addSpeaker() {
        let id = SpeakerEditor.nextSpeakerID(notIn: speakerOrder)
        speakerColors[id] = SpeakerColor.forSpeaker(atIndex: speakerOrder.count)
        speakerOrder.append(id)
    }

    /// Any speaker can be deleted. Their segments are detached rather than
    /// destroyed, and show as "Unknown" until reassigned.
    func removeSpeaker(_ speakerID: String) {
        turns = SpeakerEditor.unassigning(turns, speakerID: speakerID)
        speakerOrder.removeAll { $0 == speakerID }
        speakerNames[speakerID] = nil
        speakerColors[speakerID] = nil
    }

    // MARK: Audio playback

    func togglePlayback() {
        guard preparePlayback() else { return }
        playback.togglePlayback()
    }

    func play(turnAt index: Int) {
        guard turns.indices.contains(index),
              let start = turns[index].startTime,
              preparePlayback() else { return }
        playback.play(from: start)
    }

    func play(turnAt index: Int, characterOffset: Int) {
        guard turns.indices.contains(index),
              let start = turns[index].timestamp(atUTF16Offset: characterOffset),
              preparePlayback() else { return }
        playback.play(from: start)
    }

    /// Lets a transcript inherit a moved recording without copying it.
    func relinkAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink"
        panel.message = "Choose the audio file that belongs to this transcript"
        panel.allowedContentTypes = Self.allowedContentTypes
        if let linkedAudioURL {
            panel.directoryURL = linkedAudioURL.deletingLastPathComponent()
            panel.nameFieldStringValue = linkedAudioURL.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard isAcceptableFile(url) else {
            errorMessage = "\(url.lastPathComponent) does not look like a supported audio or video file."
            return
        }
        audioPath = url.path
        sourceFilename = url.lastPathComponent
        preparePlayback()
        saveCurrentRecord()
        errorMessage = nil
    }

    @discardableResult
    private func preparePlayback() -> Bool {
        let urls = linkedAudioURLs
        guard !urls.isEmpty,
              urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            playback.unload()
            return false
        }
        playback.load(urls)
        return true
    }

    func initial(for speakerID: String) -> String {
        TranscriptFormatter.initial(for: speakerID, names: speakerNames)
    }

    /// Says out loud what deleting will cost, since it is not undoable.
    func removalHelp(for speakerID: String) -> String {
        let name = displayName(for: speakerID)
        let count = SpeakerEditor.segmentCount(for: speakerID, in: turns)
        guard count > 0 else { return "Delete \(name)" }
        return "Delete \(name) — their \(count) segment\(count == 1 ? "" : "s") become Unknown"
    }

    // MARK: Output

    func copyTranscript() {
        guard hasTranscript else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptText, forType: .string)
    }

    func saveMarkdown() {
        guard hasTranscript else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = snapshot(id: currentRecordID ?? UUID()).suggestedFilename + ".md"
        panel.message = "Save the transcript as Markdown"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(markdownText.utf8).write(to: url, options: .atomic)
            storeWarning = nil
        } catch {
            storeWarning = "Could not write that file: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    private func snapshot(id: UUID) -> TranscriptRecord {
        TranscriptRecord(id: id,
                         title: title,
                         createdAt: currentCreatedAt,
                         sourceFilename: sourceFilename,
                         audioPath: audioPath,
                         secondaryAudioPath: secondaryAudioPath,
                         recordingMode: recordingMode,
                         detectedLanguage: detectedLanguage,
                         turns: turns,
                         fallbackText: fallbackText,
                         speakerNames: speakerNames,
                         speakerColors: speakerColors,
                         speakerOrder: speakerOrder)
    }

    private func upsert(_ record: TranscriptRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.createdAt > $1.createdAt }
    }

    /// Edits to a name, colour or title are saved on a short delay. Writing
    /// the whole transcript on every keystroke would be a lot of file I/O on
    /// a 2017 dual-core.
    private func scheduleSave() {
        guard !isLoadingRecord, hasTranscript else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveCurrentRecord()
        }
    }

    private func beginNewRecord() {
        currentRecordID = nil
        currentCreatedAt = Date()
        sourceFilename = ""
        audioPath = nil
        secondaryAudioPath = nil
        recordingMode = nil
        playback.unload()
        clearTranscript()
    }

    private func clearTranscript() {
        turns = []
        fallbackText = ""
        speakerNames = [:]
        speakerColors = [:]
        speakerOrder = []
        detectedLanguage = nil
    }

    private func persistAPIKey() {
        do {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try KeychainStore.delete()
            } else {
                try KeychainStore.save(trimmed)
            }
            keychainWarning = nil
        } catch {
            keychainWarning = "The API key could not be saved: \(error.localizedDescription)"
        }
    }

    private func isAcceptableFile(_ url: URL) -> Bool {
        MultipartBuilder.audioPathExtensions.contains(url.pathExtension.lowercased())
    }

    private static var supportedExtensionList: String {
        MultipartBuilder.audioPathExtensions.sorted().joined(separator: ", ")
    }

    private static var allowedContentTypes: [UTType] {
        let fromExtensions = MultipartBuilder.audioPathExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        return [.audio, .movie] + fromExtensions
    }

    private static func describeLanguage(_ response: TranscriptionResponse) -> String? {
        guard let code = response.languageCode else { return nil }
        guard let probability = response.languageProbability else { return code }
        return "\(code) (\(Int((probability * 100).rounded()))% confidence)"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        TranscriptionError.formatBytes(bytes)
    }
}

/// The one place `SpeakerColor` meets SwiftUI. The switch must be exhaustive,
/// so a colour cannot be added to the palette without being given a value here.
extension SpeakerColor {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .orange: return .orange
        case .green: return .green
        case .purple: return .purple
        case .pink: return .pink
        case .teal: return .teal
        case .indigo: return .indigo
        case .brown: return .brown
        case .red: return .red
        case .burgundy:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark
                    ? NSColor(srgbRed: 0.85, green: 0.44, blue: 0.53, alpha: 1)   // lighter wine
                    : NSColor(srgbRed: 0.44, green: 0.11, blue: 0.21, alpha: 1)   // deep wine
            })
        }
    }
}

// MARK: - View

private enum WorkspacePage: Equatable {
    case home
    case transcription
    case recording
}

private enum HomeAction: Hashable {
    case microphone
    case systemAudio
    case meeting
    case file
}

struct ContentView: View {

    @StateObject private var model = TranscriberModel()
    @StateObject private var recorder = AudioRecordingService()
    @State private var page: WorkspacePage = .home
    @State private var recordingMode: RecordingMode = .microphone
    @State private var recordingTitle = ""
    @State private var showLeaveRecordingWarning = false
    @State private var hoveredHomeAction: HomeAction?
    @State private var isDropTargeted = false
    @State private var isKeyVisible = false
    @State private var isKeyPopoverPresented = false
    @State private var hoveredSpeaker: String?
    @FocusState private var focusedSpeaker: String?
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    private let speakerColumnWidth: CGFloat = 104

    // MARK: Search

    private var matches: [TranscriptSearch.Match] { model.matches }

    private var matchSummary: String {
        if model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard !matches.isEmpty else { return "No matches" }
        return "\(model.clampedMatch + 1) of \(matches.count)"
    }

    /// ⌘F on an open bar re-focuses it rather than closing it, which is what
    /// every other macOS app does.
    private func openSearch() {
        isSearching = true
        searchFocused = true
    }

    private func closeSearch() {
        isSearching = false
        model.searchQuery = ""
        model.currentMatch = 0
        searchFocused = false
    }

    private func requestTranscription() {
        guard model.engine != .elevenLabs || model.hasAPIKey else {
            isKeyPopoverPresented = true
            return
        }
        Task { await model.transcribe() }
    }

    private func goHome() {
        if recorder.state == .recording || recorder.state == .starting || recorder.state == .finishing {
            showLeaveRecordingWarning = true
        } else {
            page = .home
        }
    }

    private func beginRecording(_ mode: RecordingMode) {
        recorder.reset()
        recordingMode = mode
        recordingTitle = ""
        page = .recording
    }

    private func beginFileTranscription() {
        model.newTranscription()
        page = .transcription
    }

    private func useFinishedRecording() {
        guard let result = recorder.result else { return }
        model.selectRecording(result)
        page = .transcription
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                switch page {
                case .home: homePage
                case .transcription: transcriptionPage
                case .recording: recordingPage
                }
            }
            .frame(minWidth: 640, idealWidth: 1040, minHeight: 400, idealHeight: 680)
            .toolbar { workspaceToolbar }
            .alert("Stop this recording?", isPresented: $showLeaveRecordingWarning) {
                Button("Keep Recording", role: .cancel) {}
                Button("Stop and Discard", role: .destructive) {
                    Task {
                        await recorder.discard()
                        page = .home
                    }
                }
            } message: {
                Text("Going Home would interrupt the recording. The captured audio will be discarded.")
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Button {
                goHome()
            } label: {
                Label("Home", systemImage: "house.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(page == .home ? Color.accentColor.opacity(0.16) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            HStack {
                Text("Transcriptions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)

            if model.records.isEmpty {
                // Centred with a flexible frame rather than two Spacers, which
                // would demand unbounded height the way the People panel did.
                Text("Transcriptions you make are saved here automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { page == .transcription ? model.currentRecordID : nil },
                                        set: {
                                            if let id = $0 {
                                                if id != model.currentRecordID { model.open(id) }
                                                page = .transcription
                                            }
                                        })) {
                    ForEach(model.records) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayTitle)
                                .lineLimit(1)
                            Text(record.createdAt, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(record.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.delete(record.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 190)
    }

    // MARK: Main

    private var transcriptionPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            pageHeader("Transcription")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    titleAndLanguage
                    keytermsField
                }
                dropZone
                    // Same width and gutter as the action/People rail below,
                    // so the whole interface sits on one visible grid.
                    .frame(width: 230, height: 142)
            }
            // These rows must never surrender their height to a long People
            // list. When they were compressed, their contents still painted
            // at full size and the playback bar crossed the transcript.
            .fixedSize(horizontal: false, vertical: true)
            banners
                .fixedSize(horizontal: false, vertical: true)
            if isSearching {
                searchBar
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasTranscript {
                audioControls
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                transcriptBox
                VStack(spacing: 10) {
                    actionPanel
                    // Shown whenever there is a transcript, not only when
                    // speakers exist: Add Speaker must remain reachable.
                    if model.hasTranscript {
                        peoplePanel
                    }
                }
                .frame(width: 230)
            }
            // Takes the leftover height, but with a bounded *ideal* height so
            // the window does not try to size itself to fit a whole meeting.
            .frame(minHeight: 140, idealHeight: 300, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .padding(18)
        // Clicking any empty part of the window finishes a rename. Controls
        // consume their own clicks, so this only catches the gaps.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focusedSpeaker = nil }
        )
        // Rosy's screen is 1280x800, which leaves roughly 720pt once the menu
        // bar and the title bar are gone. A 700pt minimum plus padding was
        // taller than that, so the window could not be shortened at all and
        // sprang back to full height whenever it was moved.
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if page == .transcription {
            ToolbarItem {
                Button {
                    isKeyPopoverPresented.toggle()
                } label: {
                    Image(systemName: model.hasAPIKey ? "key.fill" : "key")
                }
                .help(model.hasAPIKey ? "ElevenLabs API key" : "Add ElevenLabs API key")
                .popover(isPresented: $isKeyPopoverPresented, arrowEdge: .bottom) {
                    apiKeyPopover
                }
            }
            ToolbarItem {
                Button {
                    openSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                // In the toolbar rather than hidden away, so Find is
                // discoverable as well as reachable by shortcut.
                .keyboardShortcut("f", modifiers: .command)
                .help("Find in transcript (⌘F)")
                // Search reads the segments. A transcript that came back
                // without diarization has none, and Find would only ever be
                // able to answer "No matches".
                .disabled(model.turns.isEmpty)
            }
            ToolbarItem {
                Button {
                    model.newTranscription()
                    page = .transcription
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New transcription")
            }
        }
    }

    // MARK: Home

    private var homePage: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("What shall we capture?")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Record something new, or bring Rosy a file you already have.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                GridItem(.flexible(), spacing: 14)], spacing: 14) {
                homeAction(mode: .microphone,
                           action: .microphone,
                           tint: Color(red: 0.88, green: 0.46, blue: 0.53))
                homeAction(mode: .systemAudio,
                           action: .systemAudio,
                           tint: Color(red: 0.78, green: 0.38, blue: 0.48))
                homeAction(mode: .meeting,
                           action: .meeting,
                           tint: Color(red: 0.82, green: 0.57, blue: 0.39))

                Button(action: beginFileTranscription) {
                    homeCard(symbol: "waveform.badge.plus",
                             title: "Transcribe a File",
                             detail: "Choose an existing audio or video file.",
                             tint: Color(red: 0.91, green: 0.54, blue: 0.57),
                             isHovered: hoveredHomeAction == .file)
                }
                .buttonStyle(.plain)
                .onHover { setHomeHover(.file, hovering: $0) }
            }
            .frame(maxWidth: 760)

            Spacer()
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func homeAction(mode: RecordingMode, action: HomeAction, tint: Color) -> some View {
        Button { beginRecording(mode) } label: {
            homeCard(symbol: mode.symbol,
                     title: mode.title,
                     detail: mode.detail,
                     tint: tint,
                     isHovered: hoveredHomeAction == action)
        }
        .buttonStyle(.plain)
        .onHover { setHomeHover(action, hovering: $0) }
    }

    private func setHomeHover(_ action: HomeAction, hovering: Bool) {
        if hovering {
            hoveredHomeAction = action
        } else if hoveredHomeAction == action {
            hoveredHomeAction = nil
        }
    }

    private func homeCard(symbol: String,
                          title: String,
                          detail: String,
                          tint: Color,
                          isHovered: Bool) -> some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(tint.opacity(isHovered ? 0.28 : 0.16))
                Image(systemName: symbol)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 58, height: 58)
            .scaleEffect(isHovered ? 1.06 : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(isHovered ? tint.opacity(0.16) : Color.gray.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(isHovered ? tint.opacity(0.72) : Color.gray.opacity(0.16),
                        lineWidth: isHovered ? 1.5 : 1)
        )
        .shadow(color: isHovered ? tint.opacity(0.16) : .clear,
                radius: isHovered ? 10 : 0,
                y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 15))
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    // MARK: Recording

    private var recordingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(recordingMode.title)
                .padding(18)

            VStack(spacing: 18) {
                recordingHero
                recordingControls
            }
            .frame(maxWidth: 560)
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var recordingHero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(recordingTint.opacity(0.16))
                Image(systemName: recorder.state == .recording ? "waveform" : recordingMode.symbol)
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(recordingTint)
            }
            .frame(width: 108, height: 108)

            Text(recordingStatusTitle)
                .font(.title2.weight(.semibold))

            if recorder.state == .recording || recorder.state == .finishing || recorder.state == .finished {
                Text(Self.recordingTime(recorder.elapsed))
                    .font(.system(size: 34, weight: .medium, design: .rounded).monospacedDigit())
            } else {
                Text(recordingMode.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if recorder.state == .recording {
                audioMeters
            }
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        switch recorder.state {
        case .idle, .failed:
            VStack(spacing: 14) {
                TextField("Recording title", text: $recordingTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)

                if recordingMode == .meeting {
                    Label {
                        Text("Use earphones or headphones. Otherwise the microphone hears the other participants twice, which damages transcription and speaker separation.")
                    } icon: {
                        Image(systemName: "headphones")
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
                }

                if let error = recorder.errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)

                        if recorder.systemAudioPermissionDenied {
                            Button {
                                recorder.openSystemAudioPrivacySettings()
                            } label: {
                                Label("Open Recording Settings", systemImage: "gear")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
                }

                Button {
                    Task { await recorder.start(mode: recordingMode, title: recordingTitle) }
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .starting:
            VStack(spacing: 10) {
                ProgressView()
                Text("Requesting permission and preparing the audio tracks…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .recording:
            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Finish Recording", systemImage: "stop.fill")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

        case .finishing:
            VStack(spacing: 10) {
                ProgressView()
                Text("Finishing the audio files safely…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .finished:
            VStack(spacing: 12) {
                Text(recordingMode == .meeting
                     ? "Two separate tracks are ready: your microphone and the Mac's audio."
                     : "Your recording is ready to transcribe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await recorder.discard()
                            page = .home
                        }
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .tint(.red)

                    Button(action: useFinishedRecording) {
                        Label("Continue to Transcription", systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        }
    }

    private var audioMeters: some View {
        VStack(spacing: 8) {
            if recordingMode.needsMicrophone {
                levelRow(label: "Microphone", symbol: "mic.fill", value: recorder.microphoneLevel)
            }
            if recordingMode.needsSystemAudio {
                levelRow(label: "Mac audio", symbol: "speaker.wave.2.fill", value: recorder.systemLevel)
            }
        }
        .frame(maxWidth: 360)
    }

    private func levelRow(label: String, symbol: String, value: Double) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .frame(width: 18)
            Text(label)
                .font(.caption)
                .frame(width: 76, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.18))
                    Capsule().fill(recordingTint)
                        .frame(width: geometry.size.width * max(0.025, value))
                }
            }
            .frame(height: 7)
        }
        .foregroundStyle(.secondary)
    }

    private var recordingTint: Color {
        if recorder.state == .recording { return .red }
        switch recordingMode {
        case .microphone: return .blue
        case .systemAudio: return .purple
        case .meeting: return .orange
        }
    }

    private var recordingStatusTitle: String {
        switch recorder.state {
        case .idle: return "New \(recordingMode.title)"
        case .starting: return "Getting Ready…"
        case .recording: return "Recording"
        case .finishing: return "Saving…"
        case .finished: return recorder.result?.title ?? recordingMode.title
        case .failed: return "Could Not Start Recording"
        }
    }

    private func pageHeader(_ title: String) -> some View {
        HStack(spacing: 10) {
            Button(action: goHome) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Back to Home")
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    private static func recordingTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Meeting details

    private var titleAndLanguage: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meeting title")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Named after the file until you change it", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Language")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 132, alignment: .trailing)
            }
            .frame(width: 132, alignment: .leading)
        }
    }

    private var keytermsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Key terms")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("proferida, averbação, embargos de terceiros, Dr. Silva",
                      text: $model.keytermsText,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)
                .disabled(model.engine == .onDevice)
            Text(model.engine == .onDevice
                 ? "Key terms currently apply to ElevenLabs only."
                 : (model.keytermsProblem ?? model.keytermsSummary))
                .font(.caption)
                .foregroundStyle(model.engine == .onDevice || model.keytermsProblem == nil
                                 ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var apiKeyPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.accentColor)
                Text("ElevenLabs API Key")
                    .font(.headline)
                Spacer()
                if model.hasAPIKey {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 7) {
                Group {
                    if isKeyVisible {
                        TextField("xi-api-key", text: $model.apiKey)
                    } else {
                        SecureField("xi-api-key", text: $model.apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button {
                    isKeyVisible.toggle()
                } label: {
                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isKeyVisible ? "Hide the key" : "Show the key")
            }

            Text("Stored securely in your login Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            if let file = model.selectedFile {
                Text(file.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let size = model.selectedFileSize {
                    Text(TranscriberModel.formatBytes(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !model.sourceFilename.isEmpty {
                Text(model.sourceFilename)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Drop another file to transcribe again")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Drop an audio file here")
                    .font(.headline)
                Text("or click to choose one")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.gray.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.chooseFile() }
        // Drag-and-drop alone is a bad only-option, hence the tap gesture above.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.selectFile(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: Actions

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Transcription", selection: $model.engine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        VStack(alignment: .leading) {
                            Text(engine.displayName)
                            Text(engine.detail)
                        }
                        .tag(engine)
                        .disabled(engine == .onDevice && !LocalTranscriptionAvailability.isAvailable)
                        .help(engine == .onDevice
                              ? LocalTranscriptionAvailability.explanation
                              : "Transcribes with ElevenLabs Scribe v2.")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .help(model.engine == .onDevice
                      ? LocalTranscriptionAvailability.explanation
                      : "Choose where the audio is transcribed.")
            }

            if model.engine == .onDevice {
                HStack {
                    Text("Expected speakers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Expected speakers", selection: $model.expectedSpeakers) {
                        Text("Auto").tag(0)
                        ForEach(2...8, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 68)
                    .help("If local diarisation finds too many identities, Rosy merges the closest voices down to this number.")
                }
            }

            Button {
                requestTranscription()
            } label: {
                HStack {
                    if model.isTranscribing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "waveform")
                    }
                    Text(model.isTranscribing ? "Transcribing…" : "Transcribe")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            // Keep the button clickable when only the key is missing: that
            // click is what opens the key popover and explains what is needed.
            .disabled(model.selectedFile == nil || model.isTranscribing
                      || (model.engine == .elevenLabs && model.keytermsProblem != nil))

            Button {
                model.copyTranscript()
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.hasTranscript)

            Button {
                model.saveMarkdown()
            } label: {
                Label("Save as Markdown…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.hasTranscript)

            if model.isTranscribing {
                Text(model.engine == .onDevice
                     ? "Transcribing and separating speakers on this Mac. The first run downloads the local models."
                     : "Uploading and transcribing. Long recordings can take several minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let language = model.detectedLanguage {
                Text("Detected: \(language)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.engine == .elevenLabs && !model.hasAPIKey {
                Label("API key required", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.engine == .onDevice {
                Label("Audio stays on this Mac", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.07)))
    }

    private var banners: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let keychainWarning = model.keychainWarning {
                Text(keychainWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let storeWarning = model.storeWarning {
                Text(storeWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Playback

    private var audioControls: some View {
        Group {
            if model.isAudioAvailable {
                HStack(spacing: 10) {
                    Button {
                        model.togglePlayback()
                    } label: {
                        Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .help(model.playback.isPlaying ? "Pause" : "Play")

                    Text(Self.playbackTime(model.playback.currentTime))
                        .font(.caption.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)

                    Slider(value: Binding(get: { model.playback.currentTime },
                                          set: { model.playback.seek(to: $0) }),
                           in: 0...max(model.playback.duration, 0.01))
                        .disabled(model.playback.duration <= 0)

                    Text(Self.playbackTime(model.playback.duration))
                        .font(.caption.monospacedDigit())
                        .frame(width: 42, alignment: .leading)

                    Text(model.linkedAudioURL?.lastPathComponent ?? "Audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button("Relink…") { model.relinkAudio() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.07)))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Playback Unavailable — Audio file not found")
                            .font(.callout.weight(.medium))
                        if let path = model.audioPath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button("Relink Audio…") { model.relinkAudio() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.09)))
            }
        }
    }

    private static func playbackTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in transcript", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                // Focus is taken here rather than in openSearch(): the field
                // does not exist yet at the moment the bar is switched on, so
                // a focus write from there is dropped.
                .onAppear { searchFocused = true }
                .onSubmit { model.stepMatch(1) }
                .onExitCommand { closeSearch() }

            Text(matchSummary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button { model.stepMatch(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(matches.isEmpty)
                .help("Previous match")
            Button { model.stepMatch(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(matches.isEmpty)
                .help("Next match (↩)")
            Button { closeSearch() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close (esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
    }

    // MARK: Transcript

    private var transcriptBox: some View {
        // Grouped once per redraw rather than filtered per row: a common word
        // in a long meeting is thousands of matches, and re-scanning that list
        // for every visible row would be felt on a dual-core.
        let highlights = TranscriptSearch.rangesByTurn(matches)
        let current = matches.isEmpty ? nil : matches[model.clampedMatch]

        return ScrollViewReader { proxy in
            ScrollView {
                // Lazy, because a forty-minute meeting is hundreds of turns and
                // Rosy is a dual-core Intel.
                LazyVStack(alignment: .leading, spacing: 9) {
                    if model.turns.isEmpty {
                        Text(model.fallbackText.isEmpty
                             ? "The transcript will appear here."
                             : model.fallbackText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(model.fallbackText.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Indices rather than `enumerated()`: Swift has no key
                        // path to a tuple element, so `id: \.offset` does not
                        // compile.
                        ForEach(model.turns.indices, id: \.self) { index in
                            turnRow(at: index,
                                    highlights: highlights[index] ?? [],
                                    current: current?.turnIndex == index ? current?.range : nil)
                                .id(index)
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: model.currentMatch) { _ in scrollToMatch(proxy) }
            .onChange(of: model.searchQuery) { _ in scrollToMatch(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.07)))
        // Without this the scrolling content painted straight past the bottom
        // of the box and off the window.
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func scrollToMatch(_ proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        withAnimation { proxy.scrollTo(matches[model.clampedMatch].turnIndex, anchor: .center) }
    }


    // SwiftUI can evaluate a row for an index that has just gone away: editing
    // can delete a segment, and `ForEach` over indices only notices on the
    // next pass. Indexing straight into `turns` here would crash.
    @ViewBuilder
    private func turnRow(at index: Int,
                         highlights: [Range<String.Index>] = [],
                         current: Range<String.Index>? = nil) -> some View {
        if model.turns.indices.contains(index) {
            let turn = model.turns[index]

            // The name is repeated on every segment, including where the
            // segment above has the same speaker. This view is an editor of
            // segments, and a blank name made two segments look like one
            // merged block while hiding that the space is right-clickable.
            // Joining adjacent segments is an output concern and stays in
            // `TranscriptFormatter.merged`.
            HStack(alignment: .top, spacing: 7) {
                Text(model.displayName(for: turn.speakerID))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(turn.speakerID == nil
                                     ? Color.secondary
                                     : model.color(for: turn.speakerID).color)
                    .frame(width: speakerColumnWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // The whole column is the target, so a continuation row
                    // can be right-clicked too.
                    .contentShape(Rectangle())
                    .contextMenu { reassignmentMenu(for: index) }

                if turn.startTime != nil {
                    Button {
                        model.play(turnAt: index)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 18)
                    .disabled(!model.isAudioAvailable)
                    .help(model.isAudioAvailable
                          ? "Play from this segment"
                          : "Audio file not found — relink it to restore playback")
                }

                // Always live: click for a caret, drag to select, type to
                // edit, and search matches stay highlighted throughout.
                SegmentTextView(text: model.textBinding(at: index),
                                font: Self.transcriptFont,
                                textColor: .labelColor,
                                highlights: highlights,
                                currentHighlight: current,
                                onOptionClick: { offset in
                                    model.play(turnAt: index, characterOffset: offset)
                                },
                                onSplit: { offset in
                                    model.splitTurn(at: index, utf16Offset: offset)
                                },
                                onEditingEnded: { model.commitEdit(at: index) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Matched to `.system(.body, design: .monospaced)` on the name column, so
    /// the two halves of a row sit on the same baseline.
    private static let transcriptFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)


    @ViewBuilder
    private func reassignmentMenu(for index: Int) -> some View {
        let current = model.turns.indices.contains(index) ? model.turns[index].speakerID : nil
        // Gated on there being somewhere to move to, not on the number of
        // speakers. Delete the only speaker and everything becomes Unknown;
        // add one back and "reassign all" is exactly what you want, but a
        // count of one would have hidden it.
        let destinations = model.speakerOrder.filter { $0 != current }

        ForEach(model.speakerOrder, id: \.self) { id in
            Button {
                model.assign(turnAt: index, to: id)
            } label: {
                if id == current {
                    Label(model.displayName(for: id), systemImage: "checkmark")
                } else {
                    Text(model.displayName(for: id))
                }
            }
        }

        if !destinations.isEmpty {
            Divider()
            Menu("Reassign all of \(model.displayName(for: current))'s segments to…") {
                ForEach(destinations, id: \.self) { id in
                    Button(model.displayName(for: id)) {
                        model.reassignAll(from: current, to: id)
                    }
                }
            }
        }
    }

    // MARK: People

    private var peoplePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People")
                .font(.headline)
                .foregroundStyle(.secondary)

            // A pathological diarisation result can contain many identities.
            // Let that list scroll inside the rail instead of using its full
            // intrinsic height and crushing the header/playback rows above.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.speakerOrder.indices, id: \.self) { index in
                        personRow(model.speakerOrder[index])
                        if index < model.speakerOrder.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Button {
                model.addSpeaker()
            } label: {
                Label("Add Speaker", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Add a speaker to assign segments to")

            Text("Names apply to this transcript only — the API numbers speakers by who talks first, so they mean something different in the next recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        // Accepts the height the row offers rather than demanding all of it,
        // which a trailing Spacer() used to do.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// A badge and a name at rest; a name field, a colour menu and a delete
    /// button under the pointer.
    ///
    /// The row keeps its editing form while the field has focus, not only
    /// while hovered — otherwise nudging the mouse away mid-rename would
    /// swap the field out from under the cursor.
    private func personRow(_ id: String) -> some View {
        // Focus owns the editing state. While one field is active, hovering
        // another row must not open a second editor beside it.
        let isEditing = focusedSpeaker == id || (focusedSpeaker == nil && hoveredSpeaker == id)

        let speakerColor = model.color(for: id).color

        return HStack(spacing: 8) {
            if isEditing {
                TextField(TranscriptFormatter.label(for: id),
                          text: Binding(get: { model.speakerNames[id] ?? "" },
                                        set: { model.speakerNames[id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .foregroundStyle(speakerColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(speakerColor.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(speakerColor.opacity(0.55), lineWidth: 1)
                    )
                    .focused($focusedSpeaker, equals: id)
                    // Without these the row kept its editing form forever:
                    // nothing else on the panel takes focus, so the field
                    // never gave it up on its own.
                    .onSubmit { focusedSpeaker = nil }
                    .onExitCommand { focusedSpeaker = nil }

                Menu {
                    ForEach(SpeakerColor.allCases, id: \.self) { option in
                        Button(option.displayName) { model.speakerColors[id] = option }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 15))
                        .foregroundStyle(speakerColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Change colour")

                Button {
                    if focusedSpeaker == id { focusedSpeaker = nil }
                    model.removeSpeaker(id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(model.removalHelp(for: id))
            } else {
                ZStack {
                    Circle()
                        .fill(speakerColor)
                    Text(model.initial(for: id))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 27, height: 27)

                Text(model.displayName(for: id))
                    .font(.body.weight(.medium))
                    .foregroundStyle(speakerColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
        }
        // A fixed height, so the row does not jump as it swaps between the
        // two forms under the pointer.
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            // Clicking another person counts as clicking outside the active
            // field: close it, then let this hovered row become editable.
            if let focusedSpeaker, focusedSpeaker != id {
                self.focusedSpeaker = nil
                hoveredSpeaker = id
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredSpeaker = id
            } else if hoveredSpeaker == id {
                hoveredSpeaker = nil
            }
        }
    }
}

#if DEBUG
// The #Preview macro is macOS 14+, and this app deploys to 13.0.
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
