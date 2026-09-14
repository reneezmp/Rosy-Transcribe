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

/// A settings file held in memory, written back whenever it changes.
///
/// The panes bind straight into `values`, and that is exactly why saving
/// cannot be left to the buttons. A name typed into a `TextField` and a toggle
/// flipped in a row both mutate the array without passing through any action
/// of ours — and both were silently lost, every time, before this type
/// existed. Every mutation now schedules a write, so forgetting to call a
/// `persist…()` helper is no longer possible.
///
/// Debounced for the same reason the transcript is: on the 2017 dual-core a
/// file write per keystroke is real work. `save()` forces one out immediately
/// for structural edits — adding or deleting an entry — and `flush()` writes
/// anything still pending when the pane goes away.
@MainActor final class SettingsDocument<Value: Codable & Equatable>: ObservableObject {

    @Published var values: [Value] {
        didSet {
            guard values != oldValue else { return }
            pendingSave = true
            scheduleSave()
        }
    }
    /// Nil unless the last write failed. Surfaced by the pane, because a
    /// settings file that cannot be written is worth knowing about.
    @Published private(set) var lastError: String?

    private let store: SettingsStore<Value>
    private var saveTask: Task<Void, Never>?
    private var pendingSave = false

    init(store: SettingsStore<Value>) {
        self.store = store
        self.values = store.load()
    }

    convenience init(filename: String) {
        self.init(store: SettingsStore(filename: filename))
    }

    /// Writes now, cancelling any pending debounced write.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        pendingSave = false
        do {
            try store.save(values)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Writes only if something is actually waiting to be written.
    func flush() {
        guard pendingSave else { return }
        save()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.save()
        }
    }
}

/// The settings two screens have to agree about.
///
/// Both the Settings panes and the transcript read the People directory and
/// the ignored-segment rules, and a copy on each side is a copy that can be
/// stale: rename someone in Settings, walk back to a transcript, and the
/// People menus would offer the old name until something happened to reload
/// them. One owner, held in memory, removes the question — and removes the
/// file read from the view body at the same time. Writing to disk stays
/// debounced, because that only matters across launches.
@MainActor
enum SharedSettings {
    static let people = SettingsDocument<PersonProfile>(filename: "People.json")
    static let ignoredSegments = SettingsDocument<IgnoredSegmentRule>(filename: "IgnoredSegments.json")
}

/// Which base URLs an AI service is allowed to use.
///
/// HTTPS anywhere; plain HTTP only to this Mac or this LAN, because an API key
/// travelling in cleartext to a public host is a leak.
///
/// The check has to read the host as an *address*, not as text. The first
/// attempt matched prefixes — `host.hasPrefix("10.")` — which accepts
/// `10.evil.example.com`, a perfectly public hostname, and rejects
/// `172.16.0.5`, which is genuinely private. Prefix-matching a hostname
/// answers a different question from the one being asked.
enum LocalEndpointPolicy {

    static func allows(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isLoopbackOrPrivate(host)
    }

    static func isLoopbackOrPrivate(_ host: String) -> Bool {
        // The two names that mean "near me": loopback, and Bonjour.
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        // Anything else has to be a literal address. A name cannot be trusted,
        // because what it resolves to is not ours to decide.
        guard let octets = ipv4Octets(host) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _): return true          // 127.0.0.0/8, loopback
        case (10, _): return true           // 10.0.0.0/8
        case (172, 16...31): return true    // 172.16.0.0/12
        case (192, 168): return true        // 192.168.0.0/16
        case (169, 254): return true        // 169.254.0.0/16, link-local
        default: return false
        }
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }
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
