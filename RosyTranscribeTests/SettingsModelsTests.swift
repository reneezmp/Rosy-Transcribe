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

    // MARK: Endpoint policy

    func testHTTPSIsAllowedAnywhereAndOtherSchemesAreNot() {
        XCTAssertTrue(LocalEndpointPolicy.allows("https://api.deepseek.com"))
        XCTAssertTrue(LocalEndpointPolicy.allows("https://api.openai.com/v1"))
        XCTAssertFalse(LocalEndpointPolicy.allows("ftp://example.com"))
        XCTAssertFalse(LocalEndpointPolicy.allows("not a url"))
        XCTAssertFalse(LocalEndpointPolicy.allows(""))
    }

    func testPlainHTTPIsAllowedOnlyOnThisMacOrThisNetwork() {
        for allowed in ["http://localhost:11434",
                        "http://127.0.0.1:8080",
                        "http://mini.local:1234",
                        "http://10.0.0.4:11434",
                        "http://172.16.0.5:11434",
                        "http://172.31.255.254",
                        "http://192.168.1.10:3000",
                        "http://169.254.10.1"] {
            XCTAssertTrue(LocalEndpointPolicy.allows(allowed), allowed)
        }
        for blocked in ["http://api.openai.com",
                        "http://203.0.113.9",
                        "http://172.32.0.1",
                        "http://172.15.0.1",
                        "http://192.169.0.1",
                        "http://11.0.0.1"] {
            XCTAssertFalse(LocalEndpointPolicy.allows(blocked), blocked)
        }
    }

    /// The bug this policy replaced: `host.hasPrefix("10.")` accepts a public
    /// hostname that merely starts with those characters, which is how an API
    /// key would have travelled in cleartext to somebody else's server.
    func testPrivateLookingHostnamesAreNotTreatedAsPrivateAddresses() {
        XCTAssertFalse(LocalEndpointPolicy.allows("http://10.evil.example.com"))
        XCTAssertFalse(LocalEndpointPolicy.allows("http://192.168.evil.com"))
        XCTAssertFalse(LocalEndpointPolicy.allows("http://127.0.0.1.example.com"))
        XCTAssertFalse(LocalEndpointPolicy.allows("http://10.0.0.999"))
    }

    // MARK: Settings documents

    private func temporaryPeopleStore() -> SettingsStore<PersonProfile> {
        SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
    }

    /// The defect this type exists to make impossible: a pane binds straight
    /// into the array, so an edit that passes through no button of ours must
    /// still be written.
    func testEditingAValueInPlaceIsPersisted() {
        let store = temporaryPeopleStore()
        defer { try? FileManager.default.removeItem(at: store.url) }

        let document = SettingsDocument(store: store)
        document.values = [PersonProfile(displayName: "Speaker 2", isYou: true)]
        document.save()

        document.values[0].displayName = "Dra. Silva"
        XCTAssertNil(document.lastError)
        document.flush()

        let reloaded = SettingsDocument(store: store)
        XCTAssertEqual(reloaded.values.count, 1)
        XCTAssertEqual(reloaded.values.first?.displayName, "Dra. Silva")
        XCTAssertEqual(reloaded.values.first?.isYou, true)
    }

    func testFlushWritesNothingWhenNothingChanged() {
        let store = temporaryPeopleStore()
        defer { try? FileManager.default.removeItem(at: store.url) }

        let document = SettingsDocument(store: store)
        document.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertNil(document.lastError)
    }

    func testDisablingARuleSurvivesAReload() {
        let store = SettingsStore<IgnoredSegmentRule>(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
        defer { try? FileManager.default.removeItem(at: store.url) }

        let document = SettingsDocument(store: store)
        document.values = [IgnoredSegmentRule(text: "Obrigada.")]
        document.save()

        document.values[0].enabled = false
        document.flush()

        let reloaded = SettingsDocument(store: store)
        XCTAssertEqual(reloaded.values.first?.enabled, false)
        XCTAssertFalse(reloaded.values[0].matches("Obrigada."))
    }

    func testAvailabilityFallbacks() {
        XCTAssertEqual(TranscriptionSourceSelection.fallback(active: .elevenLabs, enabledCloud: true, localAvailable: false), .elevenLabs)
        XCTAssertEqual(TranscriptionSourceSelection.fallback(active: .elevenLabs, enabledCloud: false, localAvailable: true), .onDevice)
        XCTAssertNil(TranscriptionSourceSelection.fallback(active: .elevenLabs, enabledCloud: false, localAvailable: false))
    }
}
