import XCTest

@MainActor final class SettingsModelsTests: XCTestCase {
    private func temporaryStore() -> SettingsStore<CloudTranscriptionProvider> {
        SettingsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    func testRegistryPersistenceReloadAndNoSecretFields() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url) }
        let registry = CloudTranscriptionRegistry(store: store)
        XCTAssertTrue(registry.registerElevenLabs())
        XCTAssertTrue(registry.registerElevenLabs())
        XCTAssertEqual(registry.providers.count, 1)
        let reloaded = CloudTranscriptionRegistry(store: store)
        XCTAssertEqual(reloaded.providers, registry.providers)
        let persistedJSON = (try? String(contentsOf: store.url, encoding: .utf8)) ?? ""
        XCTAssertFalse(persistedJSON.lowercased().contains("key"))
    }

    func testRegistryEnabledFilteringDisableAndUnregister() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url) }
        let registry = CloudTranscriptionRegistry(store: store)
        registry.registerElevenLabs()
        XCTAssertEqual(registry.enabledProviders.count, 1)
        XCTAssertEqual(registry.usableProviders(credential: { _ in true }).count, 1)
        XCTAssertTrue(registry.usableProviders(credential: { _ in false }).isEmpty)
        registry.setEnabled(false, id: CloudTranscriptionProvider.elevenLabs.id)
        XCTAssertTrue(registry.enabledProviders.isEmpty)
        XCTAssertEqual(registry.providers.count, 1)
        registry.unregister(CloudTranscriptionProvider.elevenLabs.id)
        XCTAssertTrue(registry.providers.isEmpty)
    }

    func testCredentialMigrationDoesNotReenableDisabledProviderOnRelaunch() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url) }
        let registry = CloudTranscriptionRegistry(store: store)
        XCTAssertTrue(registry.registerElevenLabs())
        XCTAssertTrue(registry.setEnabled(false, id: CloudTranscriptionProvider.elevenLabs.id))

        let relaunched = CloudTranscriptionRegistry(store: store)
        XCTAssertTrue(relaunched.registerElevenLabsIfMissing())
        XCTAssertEqual(relaunched.providers.count, 1)
        XCTAssertEqual(relaunched.providers.first?.enabled, false)
    }

    func testRuleNormalizationAndWholeSegmentMatching() {
        let rule = IgnoredSegmentRule(text: "  Café   COM  ")
        XCTAssertTrue(rule.matches("cafe com"))
        XCTAssertFalse(rule.matches("A cafe com meeting"))
        XCTAssertFalse(IgnoredSegmentRule(text: "x", enabled: false).matches("x"))
    }

    func testIgnoredRemovalReMergesSameSpeaker() {
        let turns = [SpeakerTurn(speakerID: "a", text: "one"), SpeakerTurn(speakerID: "a", text: "remove"), SpeakerTurn(speakerID: "a", text: "three")]
        let result = IgnoredSegmentFiltering.applying([IgnoredSegmentRule(text: "remove")], to: turns)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "one three")
    }

    func testProviderMetadataContainsNoCredentialAndFallback() throws {
        let provider = CloudTranscriptionProvider.elevenLabs
        let data = try JSONEncoder().encode(provider)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("key"))
        XCTAssertEqual(TranscriptionSourceSelection.fallback(active: .elevenLabs, enabledCloud: false, localAvailable: true), .onDevice)
        XCTAssertNil(TranscriptionSourceSelection.fallback(active: .elevenLabs, enabledCloud: false, localAvailable: false))
    }

    func testAvailabilityFallbacks() {
        XCTAssertEqual(TranscriptionSourceSelection.fallback(active: .elevenLabs, enabledCloud: true, localAvailable: false), .elevenLabs)
        XCTAssertEqual(TranscriptionSourceSelection.fallback(active: .elevenLabs, enabledCloud: false, localAvailable: true), .onDevice)
        XCTAssertNil(TranscriptionSourceSelection.fallback(active: .elevenLabs, enabledCloud: false, localAvailable: false))
    }
}
