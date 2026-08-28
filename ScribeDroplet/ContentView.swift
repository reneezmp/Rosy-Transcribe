import SwiftUI
import AppKit
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

    init(defaults: UserDefaults = .standard, store: TranscriptStore = TranscriptStore()) {
        self.defaults = defaults
        self.store = store
        self.language = TranscriptionLanguage(rawValue: defaults.string(forKey: DefaultsKey.language) ?? "")
            ?? .portuguese
        self.keytermsText = defaults.string(forKey: DefaultsKey.keyterms) ?? ""
        self.records = store.load()

        // v1 stored the key in UserDefaults. Move it across and delete the
        // plist copy. Assigning in init does not fire didSet, which is what
        // we want: this is a load, not an edit.
        KeychainStore.migrateLegacyKeyIfNeeded(defaults: defaults)
        do {
            self.apiKey = try KeychainStore.read() ?? ""
        } catch {
            self.apiKey = ""
            self.keychainWarning = error.localizedDescription
        }
    }

    // MARK: Derived state

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canTranscribe: Bool {
        selectedFile != nil && hasAPIKey && !isTranscribing && keytermsProblem == nil
    }

    var hasTranscript: Bool {
        !turns.isEmpty || !fallbackText.isEmpty
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

    // MARK: Transcribing

    func transcribe() async {
        guard let fileURL = selectedFile else { return }

        isTranscribing = true
        errorMessage = nil
        clearTranscript()
        defer { isTranscribing = false }

        do {
            let terms = try Keyterms.validated(keytermsText)
            let request = TranscriptionRequest(fileURL: fileURL,
                                               apiKey: apiKey,
                                               languageCode: language.languageCode,
                                               keyterms: terms)
            let response = try await service.transcribe(request)

            isLoadingRecord = true
            turns = TranscriptFormatter.turns(from: response.words ?? [])
            fallbackText = response.text
            speakerOrder = TranscriptFormatter.speakerIDs(in: turns)
            speakerColors = SpeakerColor.assign(to: speakerOrder)
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

    // MARK: The library

    func open(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        saveTask?.cancel()
        isLoadingRecord = true
        currentRecordID = record.id
        currentCreatedAt = record.createdAt
        title = record.title
        sourceFilename = record.sourceFilename
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

struct ContentView: View {

    @StateObject private var model = TranscriberModel()
    @State private var isDropTargeted = false
    @State private var isKeyVisible = false
    @State private var hoveredSpeaker: String?
    @FocusState private var focusedSpeaker: String?
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    private let speakerColumnWidth: CGFloat = 120

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

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            main
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
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
                List(selection: Binding(get: { model.currentRecordID },
                                        set: { if let id = $0, id != model.currentRecordID { model.open(id) } })) {
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

    private var main: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The drop zone sits beside the fields rather than below them, so
            // the transcript gets the vertical space instead.
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    settings
                    titleField
                }
                dropZone
                    .frame(width: 200, height: 200)
            }
            controls
            banners
            if isSearching { searchBar }
            HStack(alignment: .top, spacing: 12) {
                transcriptBox
                // Shown whenever there is a transcript, not only when there
                // are speakers: deleting the last one must still leave Add
                // Speaker reachable.
                if model.hasTranscript {
                    peoplePanel
                        .frame(width: 210)
                }
            }
            // Takes the leftover height, but with a bounded *ideal* height so
            // the window does not try to size itself to fit a whole meeting.
            .frame(minHeight: 140, idealHeight: 300, maxHeight: .infinity)
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
        .frame(minWidth: 640, idealWidth: 1040, minHeight: 400, idealHeight: 680)
        // NavigationSplitView provides its own sidebar toggle; adding one
        // here produced two.
        .toolbar {
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
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New transcription")
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ElevenLabs API key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    // Masked by default, so the key does not end up in a
                    // screenshot. Revealable, because a pasted key you cannot
                    // see is a key you cannot check for a stray space.
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
            }

            Picker("Language", selection: $model.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            VStack(alignment: .leading, spacing: 4) {
                Text("Key terms")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("proferida, averbação, embargos de terceiros, Dr. Silva",
                          text: $model.keytermsText,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Text(model.keytermsProblem ?? model.keytermsSummary)
                    .font(.caption)
                    .foregroundStyle(model.keytermsProblem == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Title")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Named after the file until you change it", text: $model.title)
                .textFieldStyle(.roundedBorder)
        }
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

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.transcribe() }
            } label: {
                Text(model.isTranscribing ? "Transcribing…" : "Transcribe")
                    .frame(minWidth: 90)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canTranscribe)

            // Status sits beside the button rather than above the transcript,
            // so the transcript and People boxes start at the same height.
            if model.isTranscribing {
                ProgressView()
                    .controlSize(.small)
                Text("Uploading and transcribing. Long recordings can take several minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let language = model.detectedLanguage {
                Text("Detected language: \(language)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Save as Markdown…") { model.saveMarkdown() }
                .disabled(!model.hasTranscript)
            Button("Copy All") { model.copyTranscript() }
                .disabled(!model.hasTranscript)
        }
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
                LazyVStack(alignment: .leading, spacing: 10) {
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
            HStack(alignment: .top, spacing: 10) {
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

                // Always live: click for a caret, drag to select, type to
                // edit, and search matches stay highlighted throughout.
                SegmentTextView(text: model.textBinding(at: index),
                                font: Self.transcriptFont,
                                textColor: .labelColor,
                                highlights: highlights,
                                currentHighlight: current,
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
        VStack(alignment: .leading, spacing: 8) {
            Text("People")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(model.speakerOrder.indices, id: \.self) { index in
                    personRow(model.speakerOrder[index])
                    if index < model.speakerOrder.count - 1 {
                        Divider()
                    }
                }
            }

            Button {
                model.addSpeaker()
            } label: {
                Label("Add Speaker", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Add a speaker to assign segments to")

            Text("Names apply to this transcript only — the API numbers speakers by who talks first, so they mean something different in the next recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        // Accepts the height the row offers rather than demanding all of it,
        // which a trailing Spacer() used to do.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// A badge and a name at rest; a name field, a colour menu and a delete
    /// button under the pointer.
    ///
    /// The row keeps its editing form while the field has focus, not only
    /// while hovered — otherwise nudging the mouse away mid-rename would
    /// swap the field out from under the cursor.
    private func personRow(_ id: String) -> some View {
        let isEditing = hoveredSpeaker == id || focusedSpeaker == id

        return HStack(spacing: 6) {
            if isEditing {
                TextField(TranscriptFormatter.label(for: id),
                          text: Binding(get: { model.speakerNames[id] ?? "" },
                                        set: { model.speakerNames[id] = $0 }))
                    .textFieldStyle(.roundedBorder)
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
                        .foregroundStyle(model.color(for: id).color)
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
                }
                .buttonStyle(.borderless)
                .help(model.removalHelp(for: id))
            } else {
                ZStack {
                    Circle()
                        .fill(model.color(for: id).color)
                    Text(model.initial(for: id))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)

                Text(model.displayName(for: id))
                    .foregroundStyle(model.color(for: id).color)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
        }
        // A fixed height, so the row does not jump as it swaps between the
        // two forms under the pointer.
        .frame(height: 30)
        .contentShape(Rectangle())
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
