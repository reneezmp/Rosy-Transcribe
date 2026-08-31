import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AppKit

enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case meeting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Voice Note"
        case .systemAudio: return "System Audio"
        case .meeting: return "Meeting"
        }
    }

    var detail: String {
        switch self {
        case .microphone: return "Record your microphone for notes and dictation."
        case .systemAudio: return "Record sound playing anywhere on this Mac."
        case .meeting: return "Keep your microphone and everyone else on separate tracks."
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "macbook.and.iphone"
        case .meeting: return "person.2.wave.2.fill"
        }
    }

    var needsMicrophone: Bool { self != .systemAudio }
    var needsSystemAudio: Bool { self != .microphone }
}

struct RecordedAudio: Equatable {
    let mode: RecordingMode
    let title: String
    let duration: TimeInterval
    let microphoneURL: URL?
    let systemAudioURL: URL?

    var primaryURL: URL? { systemAudioURL ?? microphoneURL }
    var allURLs: [URL] { [systemAudioURL, microphoneURL].compactMap { $0 } }
}

enum AudioRecordingError: LocalizedError {
    case microphoneDenied
    case systemAudioDenied
    case microphoneUnavailable
    case displayUnavailable
    case noAudioCaptured(RecordingMode)
    case cannotCreateStorage(String)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Allow Rosy Transcribe in System Settings → Privacy & Security → Microphone, then try again."
        case .systemAudioDenied:
            return "System audio access is off. In System Settings, open Privacy & Security → Screen & System Audio Recording and enable Rosy Transcribe. Then quit and reopen Rosy before trying again."
        case .microphoneUnavailable:
            return "The selected microphone is not producing an audio format. Check the Mac's Sound input settings and try again."
        case .displayUnavailable:
            return "Rosy could not find a display to use for system-audio capture."
        case .noAudioCaptured(let mode):
            return mode == .systemAudio
                ? "No system audio was captured. Make sure something is playing and that Screen Recording permission is enabled."
                : "The recording finished without any usable audio."
        case .cannotCreateStorage(let detail):
            return "Rosy could not create its recording folder: \(detail)"
        case .captureFailed(let detail):
            return "Recording stopped because macOS reported: \(detail)"
        }
    }
}

/// Captures microphone and system sound into independent Core Audio files.
///
/// The two sources are deliberately never mixed. A meeting therefore keeps
/// the local speaker recoverable even when diarisation struggles, and both
/// tracks can later be transcribed independently and played on one timeline.
final class AudioRecordingService: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case starting
        case recording
        case finishing
        case finished
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0
    @Published private(set) var result: RecordedAudio?
    @Published private(set) var errorMessage: String?
    @Published private(set) var systemAudioPermissionDenied = false

    private let microphoneEngine = AVAudioEngine()
    private var microphoneFile: AVAudioFile?
    private var microphoneTapInstalled = false
    private var systemFile: AVAudioFile?
    private var stream: SCStream?
    private let systemQueue = DispatchQueue(label: "com.rosy.RosyTranscribe.system-audio")
    private var timer: Timer?
    private var startedAt: Date?
    private var mode: RecordingMode?
    private var recordingTitle = ""
    private var directory: URL?

    func reset() {
        guard state != .recording && state != .starting && state != .finishing else { return }
        result = nil
        errorMessage = nil
        systemAudioPermissionDenied = false
        elapsed = 0
        microphoneLevel = 0
        systemLevel = 0
        state = .idle
    }

    @MainActor
    func start(mode: RecordingMode, title: String) async {
        guard state == .idle || state == .finished || state == .failed else { return }
        reset()
        state = .starting
        self.mode = mode
        recordingTitle = Self.nonemptyTitle(title, mode: mode)

        do {
            let directory = try Self.makeRecordingDirectory()
            self.directory = directory

            // Resolve every human permission prompt before either timeline
            // begins. No track should quietly record while the user is still
            // deciding whether to grant the other source.
            if mode.needsMicrophone {
                guard await Self.requestMicrophoneAccess() else {
                    throw AudioRecordingError.microphoneDenied
                }
            }

            // Establish system capture first. Its first permission prompt can
            // sit on screen for minutes; starting the microphone before that
            // would bake those minutes into only one meeting track and make
            // their transcript timelines impossible to align.
            if mode.needsSystemAudio {
                try await startSystemAudio(at: directory.appendingPathComponent("system.caf"))
            }
            if mode.needsMicrophone {
                try startMicrophone(at: directory.appendingPathComponent("microphone.caf"))
            }

            startedAt = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
            state = .recording
        } catch {
            await tearDownCapture()
            // ScreenCaptureKit's denial text is an implementation detail
            // (currently a raw "declined TCCs" message). Translate it into
            // something a person can act on, and expose the recovery button.
            if mode.needsSystemAudio && !CGPreflightScreenCaptureAccess() {
                systemAudioPermissionDenied = true
                errorMessage = AudioRecordingError.systemAudioDenied.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            state = .failed
        }
    }

    /// Opens the exact privacy category used by ScreenCaptureKit. If a future
    /// macOS release changes the deep link, fall back to Privacy & Security
    /// instead of leaving the button apparently broken.
    @MainActor
    func openSystemAudioPrivacySettings() {
        let workspace = NSWorkspace.shared
        let recordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !workspace.open(recordingPane),
           let privacyPane = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            workspace.open(privacyPane)
        }
    }

    @MainActor
    func stop() async {
        guard state == .recording, let mode else { return }
        state = .finishing
        timer?.invalidate()
        timer = nil
        let finalDuration = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        elapsed = finalDuration

        await tearDownCapture()

        let micURL = existingTrack(named: "microphone.caf")
        let systemURL = existingTrack(named: "system.caf")
        guard (mode.needsMicrophone && micURL != nil) || (mode.needsSystemAudio && systemURL != nil) else {
            errorMessage = AudioRecordingError.noAudioCaptured(mode).localizedDescription
            state = .failed
            return
        }

        result = RecordedAudio(mode: mode,
                               title: recordingTitle,
                               duration: max(0, finalDuration),
                               microphoneURL: micURL,
                               systemAudioURL: systemURL)
        state = .finished
    }

    @MainActor
    func discard() async {
        timer?.invalidate()
        timer = nil
        await tearDownCapture()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        mode = nil
        reset()
    }

    private func startMicrophone(at url: URL) throws {
        let input = microphoneEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecordingError.microphoneUnavailable
        }

        microphoneFile = try AVAudioFile(forWriting: url,
                                         settings: format.settings,
                                         commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.microphoneFile?.write(from: buffer)
                let level = Self.level(of: buffer)
                DispatchQueue.main.async { self.microphoneLevel = level }
            } catch {
                DispatchQueue.main.async { self.failDuringCapture(error) }
            }
        }
        microphoneTapInstalled = true
        microphoneEngine.prepare()
        try microphoneEngine.start()
    }

    @MainActor
    private func startSystemAudio(at url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw AudioRecordingError.displayUnavailable
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: excluded,
                                     exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Video is not consumed, but ScreenCaptureKit still requires a tiny
        // valid screen configuration to establish the audio stream.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        self.stream = stream
        self.pendingSystemURL = url
        try await stream.startCapture()
    }

    private var pendingSystemURL: URL?

    @MainActor
    private func tearDownCapture() async {
        if microphoneTapInstalled {
            microphoneEngine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        microphoneEngine.stop()
        microphoneFile = nil

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        systemQueue.sync { self.systemFile = nil }
        pendingSystemURL = nil
        startedAt = nil
        microphoneLevel = 0
        systemLevel = 0
    }

    private func existingTrack(named name: String) -> URL? {
        guard let url = directory?.appendingPathComponent(name),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else { return nil }
        return url
    }

    @MainActor
    private func failDuringCapture(_ error: Error) {
        guard state == .recording else { return }
        errorMessage = AudioRecordingError.captureFailed(error.localizedDescription).localizedDescription
        state = .failed
        Task { await tearDownCapture() }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    private static func makeRecordingDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base
            .appendingPathComponent("RosyTranscribe", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return directory
        } catch {
            throw AudioRecordingError.cannotCreateStorage(error.localizedDescription)
        }
    }

    private static func nonemptyTitle(_ title: String, mode: RecordingMode) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(mode.title) — \(formatter.string(from: Date()))"
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let value = samples[index]
            sum += value * value
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // Useful visual range rather than a laboratory meter.
        return min(1, max(0, Double((20 * log10(max(rms, 0.000_001)) + 55) / 55)))
    }
}

extension AudioRecordingService: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, let url = pendingSystemURL else { return }
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
                let format = withUnsafePointer(to: &description) {
                    AVAudioFormat(streamDescription: $0)
                }
                guard let format,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    bufferListNoCopy: audioBufferList.unsafePointer) else { return }
                if systemFile == nil {
                    systemFile = try AVAudioFile(forWriting: url,
                                                 settings: format.settings,
                                                 commonFormat: format.commonFormat,
                                                 interleaved: format.isInterleaved)
                }
                try systemFile?.write(from: buffer)
                let level = Self.level(of: buffer)
                DispatchQueue.main.async { self.systemLevel = level }
            }
        } catch {
            DispatchQueue.main.async { self.failDuringCapture(error) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.failDuringCapture(error) }
    }
}
