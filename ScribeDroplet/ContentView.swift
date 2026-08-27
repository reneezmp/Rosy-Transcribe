import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - View model

/// All state and all work. Marked `@MainActor`, so every published property is
/// mutated on the main thread; the actual networking happens inside
/// `URLSession`, which is off the main thread by construction.
@MainActor
final class TranscriberModel: ObservableObject {

    @Published var selectedFile: URL?
    @Published var selectedFileSize: Int64?
    @Published var transcript: String = ""
    @Published var detectedLanguage: String?
    @Published var errorMessage: String?
    @Published var isTranscribing: Bool = false

    private let service = TranscriptionService()

    var canTranscribe: Bool {
        selectedFile != nil && !isTranscribing
    }

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

    func transcribe(apiKey: String, language: TranscriptionLanguage) async {
        guard let fileURL = selectedFile else { return }

        isTranscribing = true
        errorMessage = nil
        transcript = ""
        detectedLanguage = nil
        defer { isTranscribing = false }

        let request = TranscriptionRequest(fileURL: fileURL,
                                           apiKey: apiKey,
                                           languageCode: language.languageCode)
        do {
            let response = try await service.transcribe(request)
            transcript = TranscriptFormatter.format(words: response.words, fallbackText: response.text)
            detectedLanguage = Self.describeLanguage(response)
            if transcript.isEmpty {
                errorMessage = "The transcription came back empty. There may be no speech in that file."
            }
        } catch {
            // localizedDescription carries the actionable text for
            // TranscriptionError; anything else falls back to its own.
            errorMessage = error.localizedDescription
        }
    }

    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
    }

    // MARK: - Helpers

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

    // UserDefaults, not the Keychain. Good enough for a first build; see the
    // README for why it is worth moving before this key gets valuable.
    @AppStorage("elevenLabsAPIKey") private var apiKey: String = ""
    @AppStorage("transcriptionLanguage") private var languageRawValue: String = TranscriptionLanguage.portuguese.rawValue

    @StateObject private var model = TranscriberModel()
    @State private var isDropTargeted = false

    private var language: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: languageRawValue) ?? .auto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settings
            dropZone
            controls
            resultArea
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 620)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ElevenLabs API key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("xi-api-key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Picker("Language", selection: $languageRawValue) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
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
                Task { await model.transcribe(apiKey: apiKey, language: language) }
            } label: {
                Text(model.isTranscribing ? "Transcribing…" : "Transcribe")
                    .frame(minWidth: 90)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canTranscribe || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
