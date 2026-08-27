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
    @Published var transcript: String = ""
    @Published var detectedLanguage: String?
    @Published var errorMessage: String?
    @Published var isTranscribing: Bool = false
    /// Surfaced separately from `errorMessage`: a Keychain failure is about
    /// saving settings, not about the transcription that just ran.
    @Published var keychainWarning: String?

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
        transcript = ""
        detectedLanguage = nil
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
        transcript = ""
        detectedLanguage = nil
        defer { isTranscribing = false }

        do {
            let terms = try Keyterms.validated(keytermsText)
            let request = TranscriptionRequest(fileURL: fileURL,
                                               apiKey: apiKey,
                                               languageCode: language.languageCode,
                                               keyterms: terms)
            let response = try await service.transcribe(request)
            transcript = TranscriptFormatter.format(words: response.words, fallbackText: response.text)
            detectedLanguage = Self.describeLanguage(response)
            if transcript.isEmpty {
                errorMessage = "The transcription came back empty. There may be no speech in that file."
            }
        } catch {
            // localizedDescription carries the actionable text for both
            // TranscriptionError and KeytermsError.
            errorMessage = error.localizedDescription
        }
    }

    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
    }

    // MARK: Helpers

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

// MARK: - View

struct ContentView: View {

    @StateObject private var model = TranscriberModel()
    @State private var isDropTargeted = false
    @State private var isKeyVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settings
            dropZone
            controls
            resultArea
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 680)
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
        .padding(.vertical, 26)
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
                .disabled(model.transcript.isEmpty)
        }
    }

    // MARK: Result

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
                Text(model.transcript.isEmpty ? "The transcript will appear here." : model.transcript)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(model.transcript.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.07))
            )
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
