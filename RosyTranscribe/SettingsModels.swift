import Foundation
import Combine

enum CloudProviderKind: String, Codable { case elevenLabs }

struct CloudTranscriptionProvider: Codable, Identifiable, Equatable {
    let id: String
    var kind: CloudProviderKind
    var displayName: String
    var modelName: String
    var enabled: Bool
    static let elevenLabs = CloudTranscriptionProvider(id: "elevenlabs-scribe-v2", kind: .elevenLabs, displayName: "ElevenLabs Scribe v2", modelName: "scribe_v2", enabled: true)
}

@MainActor final class CloudTranscriptionRegistry: ObservableObject {
    static let shared = CloudTranscriptionRegistry()
    private let store: SettingsStore<CloudTranscriptionProvider>
    @Published private(set) var providers: [CloudTranscriptionProvider]
    @Published private(set) var lastError: String?
    init(store: SettingsStore<CloudTranscriptionProvider> = SettingsStore(filename: "CloudTranscriptionProviders.json")) { self.store = store; providers = store.load() }
    var enabledProviders: [CloudTranscriptionProvider] { providers.filter(\.enabled) }
    func usableProviders(credential: (CloudTranscriptionProvider) -> Bool) -> [CloudTranscriptionProvider] { enabledProviders.filter(credential) }
    /// Used only when adopting a credential created by an older Rosy build.
    /// An existing registration may deliberately be disabled, so migration
    /// must never turn it back on merely because the credential still exists.
    @discardableResult func registerElevenLabsIfMissing(enabled: Bool = true) -> Bool {
        guard !providers.contains(where: { $0.id == CloudTranscriptionProvider.elevenLabs.id }) else { return true }
        return registerElevenLabs(enabled: enabled)
    }
    @discardableResult func registerElevenLabs(enabled: Bool = true) -> Bool { let old = providers; if let i = providers.firstIndex(where: { $0.id == CloudTranscriptionProvider.elevenLabs.id }) { providers[i].enabled = enabled } else { providers.append(.init(id: CloudTranscriptionProvider.elevenLabs.id, kind: .elevenLabs, displayName: "ElevenLabs Scribe v2", modelName: "scribe_v2", enabled: enabled)) }; return persist(old: old) }
    @discardableResult func setEnabled(_ enabled: Bool, id: String) -> Bool { guard let i = providers.firstIndex(where: { $0.id == id }) else { return false }; let old = providers; providers[i].enabled = enabled; return persist(old: old) }
    @discardableResult func unregister(_ id: String) -> Bool { let old = providers; providers.removeAll { $0.id == id }; return persist(old: old) }
    @discardableResult private func persist(old: [CloudTranscriptionProvider]) -> Bool { do { try store.save(providers); lastError = nil; return true } catch { providers = old; lastError = error.localizedDescription; return false } }
}

enum TranscriptionSourceSelection {
    static func fallback(active: TranscriptionEngine, enabledCloud: Bool, localAvailable: Bool) -> TranscriptionEngine? {
        if active == .elevenLabs && enabledCloud { return .elevenLabs }
        if localAvailable { return .onDevice }
        return enabledCloud ? .elevenLabs : nil
    }
}

struct PersonProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var displayName: String
    var aliases: [String] = []
    var color: SpeakerColor = .blue
    var isYou: Bool = false
}

struct IgnoredSegmentRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var enabled: Bool = true
    var normalizedText: String { Self.normalize(text) }
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }
    func matches(_ segment: String) -> Bool { enabled && normalizedText == Self.normalize(segment) }
}

struct AIServiceProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    var modelID: String
    var enabled: Bool = true
}

struct SettingsEnvelope<Value: Codable>: Codable {
    var schemaVersion: Int = 1
    var values: [Value]
}

struct SettingsStore<Value: Codable> {
    let url: URL
    init(filename: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = base.appendingPathComponent("RosyTranscribe", isDirectory: true).appendingPathComponent(filename)
    }
    init(url: URL) { self.url = url }
    func load() -> [Value] {
        guard let data = try? Data(contentsOf: url), let envelope = try? JSONDecoder().decode(SettingsEnvelope<Value>.self, from: data) else { return [] }
        return envelope.values
    }
    func save(_ values: [Value]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(SettingsEnvelope(values: values)).write(to: url, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum IgnoredSegmentFiltering {
    static func applying(_ rules: [IgnoredSegmentRule], to turns: [SpeakerTurn]) -> [SpeakerTurn] {
        TranscriptFormatter.merged(turns.filter { turn in !rules.contains { $0.matches(turn.text) } })
    }
}
