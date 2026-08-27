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

    // MARK: Transcription state

    @Published var selectedFile: URL?
    @Published var selectedFileSize: Int64?
    @Published var turns: [SpeakerTurn] = []
    /// The flat transcript, shown when diarization produced nothing to group.
    @Published var fallbackText: String = ""
    @Published var detectedLanguage: String?
    @Published var errorMessage: String?
    @Published var isTranscribing: Bool = false
    @Published var keychainWarning: String?

    /// Names and colours assigned to `speaker_0`, `speaker_1`, …
    ///
    /// Deliberately reset with each new transcription. The API assigns speaker
    /// ids by order of first appearance, so `speaker_0` is a different person
    /// in every recording — carrying names across files would mislabel more
    /// often than it helped.
    @Published var speakerNames: [String: String] = [:]
    @Published var speakerColors: [String: SpeakerColor] = [:]

    private let defaults: UserDefaults
    private let service = TranscriptionService()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.language = TranscriptionLanguage(rawValue: defaults.string(forKey: DefaultsKey.language) ?? "")
            ?? .portuguese
        self.keytermsText = defaults.string(forKey: DefaultsKey.keyterms) ?? ""

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

    /// The speakers found, in order of first appearance — the order the People
    /// panel lists them in and the order colours were handed out in.
    var speakerIDs: [String] {
        TranscriptFormatter.speakerIDs(in: turns)
    }

    /// The whole transcript as text, with the assigned names. This is what
    /// Copy All puts on the pasteboard.
    var transcriptText: String {
        TranscriptFormatter.format(turns: turns, names: speakerNames, fallbackText: fallbackText)
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

    // MARK: Actions

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
        clearTranscript()
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

            turns = TranscriptFormatter.turns(from: response.words ?? [])
            fallbackText = response.text
            speakerColors = SpeakerColor.assign(to: speakerIDs)
            detectedLanguage = Self.describeLanguage(response)

            if !hasTranscript {
                errorMessage = "The transcription came back empty. There may be no speech in that file."
            }
        } catch {
            // localizedDescription carries the actionable text for both
            // TranscriptionError and KeytermsError.
            errorMessage = error.localizedDescription
        }
    }

    func copyTranscript() {
        guard hasTranscript else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptText, forType: .string)
    }

    // MARK: Helpers

    private func clearTranscript() {
        turns = []
        fallbackText = ""
        speakerNames = [:]
        speakerColors = [:]
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
        }
    }
}

// MARK: - View

struct ContentView: View {

    @StateObject private var model = TranscriberModel()
    @State private var isDropTargeted = false
    @State private var isKeyVisible = false

    private let speakerColumnWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settings
            dropZone
            controls
            HStack(alignment: .top, spacing: 12) {
                resultArea
                if !model.speakerIDs.isEmpty {
                    peoplePanel
                        .frame(width: 210)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 700)
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
                if let keychainWarning = model.keychainWarning {
                    Text(keychainWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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
                TextField("proferida, averbação, embargos de terceiros, Dr. Christopher",
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

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
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
            } else {
                Text("Drop an audio file here")
                    .font(.headline)
                Text("or click to choose one")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
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

            if model.isTranscribing {
                ProgressView()
                    .controlSize(.small)
                Text("Uploading and transcribing. Long recordings can take several minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Copy All") { model.copyTranscript() }
                .disabled(!model.hasTranscript)
        }
    }

    // MARK: Transcript

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language = model.detectedLanguage {
                Text("Detected language: \(language)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                        // Indices rather than `enumerated()`: Swift has no
                        // key path to a tuple element, so `id: \.offset`
                        // does not compile.
                        ForEach(model.turns.indices, id: \.self) { index in
                            turnRow(model.turns[index])
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.07))
            )
        }
    }

    private func turnRow(_ turn: SpeakerTurn) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(model.displayName(for: turn.speakerID))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(model.color(for: turn.speakerID).color)
                .frame(width: speakerColumnWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(turn.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: People

    private var peoplePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(model.speakerIDs, id: \.self) { id in
                HStack(spacing: 6) {
                    Menu {
                        ForEach(SpeakerColor.allCases, id: \.self) { option in
                            Button(option.displayName) { model.speakerColors[id] = option }
                        }
                    } label: {
                        Circle()
                            .fill(model.color(for: id).color)
                            .frame(width: 13, height: 13)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Change speaker colour")

                    // The placeholder is the default label, so an empty field
                    // shows exactly what the transcript shows.
                    TextField(TranscriptFormatter.label(for: id),
                              text: Binding(get: { model.speakerNames[id] ?? "" },
                                            set: { model.speakerNames[id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("Names apply to this transcript only — the API numbers speakers by who talks first, so they mean something different in the next recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.07)))
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
