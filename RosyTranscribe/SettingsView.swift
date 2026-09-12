import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case cloud = "Cloud Transcription", local = "Local Transcription", people = "People", ignored = "Ignored Segments", ai = "AI Services"
    var id: String { rawValue }
    var icon: String { switch self { case .cloud: return "cloud"; case .local: return "desktopcomputer"; case .people: return "person.2"; case .ignored: return "eye.slash"; case .ai: return "sparkles" } }
}

struct SettingsView: View {
    @Binding var elevenLabsAPIKey: String
    @StateObject private var cloudRegistry = CloudTranscriptionRegistry.shared
    @State private var category: SettingsCategory = .cloud
    @State private var apiKeyDraft = ""
    @State private var keyVisible = false
    @State private var keyStatus = ""
    @State private var confirmDeleteKey = false
    @State private var people: [PersonProfile] = SettingsStore<PersonProfile>(filename: "People.json").load()
    @State private var rules: [IgnoredSegmentRule] = SettingsStore<IgnoredSegmentRule>(filename: "IgnoredSegments.json").load()
    @State private var services: [AIServiceProfile] = SettingsStore<AIServiceProfile>(filename: "AIServices.json").load()
    @State private var aiKeys: [UUID: String] = [:]
    @State private var visibleAIKey: UUID?
    @State private var newPerson = ""
    @State private var peopleStatus = ""
    @State private var newRule = ""
    @State private var newService = ""
    @State private var serviceStatus = ""
    private let rose = Color(red: 0.72, green: 0.40, blue: 0.44)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings").font(.title3.bold()).padding(.bottom, 10)
                ForEach(SettingsCategory.allCases) { item in
                    Button { category = item } label: { Label(item.rawValue, systemImage: item.icon).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(category == item ? rose.opacity(0.16) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(20).frame(width: 205).background(.quaternary.opacity(0.25))
            ScrollView { VStack(alignment: .leading, spacing: 18) { Text(category.rawValue).font(.largeTitle.bold()); pane }.padding(32).frame(maxWidth: 760, alignment: .leading) }.frame(maxWidth: .infinity, alignment: .leading)
        }.task { normalizePeople(); loadKey(); for service in services { aiKeys[service.id] = (try? KeychainStore.read(account: service.id.uuidString)) ?? "" } }
        .alert("Delete ElevenLabs key?", isPresented: $confirmDeleteKey) { Button("Cancel", role: .cancel) {}; Button("Delete", role: .destructive) { deleteKey() } } message: { Text("This removes the credential and unregisters ElevenLabs from the picker.") }
    }

    @ViewBuilder private var pane: some View {
        switch category {
        case .cloud: cloudPane
        case .local: localPane
        case .people: peoplePane
        case .ignored: ignoredPane
        case .ai: aiPane
        }
    }
    private var cloudPane: some View { GroupBox("ElevenLabs") { VStack(alignment: .leading, spacing: 12) { Text("Your key is stored in the macOS Keychain and is never logged.").foregroundStyle(.secondary); HStack { if keyVisible { TextField("API key", text: $apiKeyDraft) } else { SecureField("API key", text: $apiKeyDraft) }; Button(keyVisible ? "Hide" : "Reveal") { keyVisible.toggle() }; Button("Save") { saveKey() }; Button("Delete", role: .destructive) { confirmDeleteKey = true } }; Toggle("Available in transcription engine", isOn: Binding(get: { cloudRegistry.providers.first(where: { $0.id == CloudTranscriptionProvider.elevenLabs.id })?.enabled ?? false }, set: { enabled in if enabled { let persisted = (try? KeychainStore.read()) ?? ""; if persisted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { keyStatus = "Save an API key before enabling ElevenLabs." } else { cloudRegistry.registerElevenLabs() } } else { cloudRegistry.setEnabled(false, id: CloudTranscriptionProvider.elevenLabs.id) } })); if let error = cloudRegistry.lastError { Text("Could not persist provider settings: \(error)").font(.caption).foregroundStyle(.red) }; if !keyStatus.isEmpty { Text(keyStatus).font(.caption).foregroundStyle(.secondary) } } .padding(4) } }
    private var localPane: some View { GroupBox("On-device transcription") { VStack(alignment: .leading, spacing: 10) { Label(LocalTranscriptionAvailability.isAvailable ? "Apple Speech is available" : "Apple Speech is unavailable", systemImage: LocalTranscriptionAvailability.isAvailable ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(LocalTranscriptionAvailability.isAvailable ? .green : .secondary); Text("Apple Speech uses locale assets installed by macOS; those assets are not Whisper model sizes.").foregroundStyle(.secondary); Text("Whisper Base and Whisper Small slots are reserved for a future local engine. No downloads are performed in this milestone.").foregroundStyle(.secondary) } .padding(4) } }
    private var peoplePane: some View { GroupBox("People directory") { VStack(alignment: .leading) { HStack { TextField("Display name", text: $newPerson); Button("Add") { addPerson() }.disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty) }; if !peopleStatus.isEmpty { Text(peopleStatus).font(.caption).foregroundStyle(.red) }; ForEach($people) { $person in HStack { Circle().fill(person.color.swiftUIColor).frame(width: 10, height: 10); TextField("Name", text: $person.displayName); Menu { ForEach(SpeakerColor.allCases, id: \.self) { color in Button(color.displayName) { person.color = color; persistPeople() } } } label: { Image(systemName: "paintpalette") }; Toggle("You", isOn: Binding(get: { person.isYou }, set: { setYou(personID: person.id, value: $0) })); Button(role: .destructive) { let wasYou = person.isYou; people.removeAll { $0.id == person.id }; if wasYou, !people.isEmpty { people[0].isYou = true }; persistPeople() } label: { Image(systemName: "trash") } } } }.padding(4) } }
    private var ignoredPane: some View { GroupBox("Whole-segment rules") { VStack(alignment: .leading) { HStack { TextField("Exact segment to hide", text: $newRule); Button("Add") { addRule() }.disabled(newRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }; ForEach($rules) { $rule in HStack { Toggle("", isOn: $rule.enabled).labelsHidden(); Text(rule.text); Spacer(); Button(role: .destructive) { rules.removeAll { $0.id == rule.id }; persistRules() } label: { Image(systemName: "trash") } } }; Text("Matching is normalized and whole-segment only; longer sentences remain untouched.").font(.caption).foregroundStyle(.secondary) }.padding(4) } }
    private var aiPane: some View { GroupBox("Registered providers") { VStack(alignment: .leading) { HStack { TextField("Custom service name", text: $newService); Button("Add DeepSeek") { addDeepSeek() }; Button("Add custom") { addService() }.disabled(newService.isEmpty) }; if !serviceStatus.isEmpty { Text(serviceStatus).font(.caption).foregroundStyle(.red) }; if services.isEmpty { Text("No AI services registered. Registration does not make paid requests.").foregroundStyle(.secondary) }; ForEach(services) { service in VStack(alignment: .leading, spacing: 5) { HStack { Image(systemName: "sparkles"); TextField("Name", text: serviceBinding(service.id, .name)); TextField("Base URL", text: serviceBinding(service.id, .baseURL)); TextField("Model", text: serviceBinding(service.id, .modelID)); Toggle("Enabled", isOn: Binding(get: { service.enabled }, set: { updateService(service, enabled: $0) })).labelsHidden(); Button("Save") { saveService(service.id) }; Button(role: .destructive) { services.removeAll { $0.id == service.id }; try? SettingsStore<AIServiceProfile>(filename: "AIServices.json").save(services); try? KeychainStore.delete(account: service.id.uuidString) } label: { Image(systemName: "trash") } }; if service.baseURL.lowercased().hasPrefix("http://") { Text("Local-network HTTP only; public HTTP endpoints are blocked.").font(.caption).foregroundStyle(.orange) }; HStack { if visibleAIKey == service.id { TextField("API key", text: keyBinding(for: service.id)) } else { SecureField("API key", text: keyBinding(for: service.id)) }; Button(visibleAIKey == service.id ? "Hide" : "Reveal") { visibleAIKey = visibleAIKey == service.id ? nil : service.id }; Button("Save key") { try? KeychainStore.save(aiKeys[service.id] ?? "", account: service.id.uuidString) } }.padding(.leading, 22) } } }.padding(4) } }
    private func loadKey() { apiKeyDraft = (try? KeychainStore.read()) ?? "" }
    private func keyBinding(for id: UUID) -> Binding<String> { Binding(get: { aiKeys[id] ?? "" }, set: { aiKeys[id] = $0 }) }
    private enum ServiceField { case name, baseURL, modelID }
    private func serviceBinding(_ id: UUID, _ field: ServiceField) -> Binding<String> { Binding(get: { guard let s = services.first(where: { $0.id == id }) else { return "" }; switch field { case .name: return s.name; case .baseURL: return s.baseURL; case .modelID: return s.modelID } }, set: { guard let i = services.firstIndex(where: { $0.id == id }) else { return }; switch field { case .name: services[i].name = $0; case .baseURL: services[i].baseURL = $0; case .modelID: services[i].modelID = $0 } }) }
    private func saveService(_ id: UUID) { guard let service = services.first(where: { $0.id == id }) else { return }; guard isAllowedURL(service.baseURL) else { serviceStatus = "Invalid URL: use HTTPS, or HTTP on localhost/private network only."; return }; serviceStatus = ""; try? SettingsStore<AIServiceProfile>(filename: "AIServices.json").save(services) }
    private func isAllowedURL(_ value: String) -> Bool { guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), let host = url.host else { return false }; if scheme == "https" { return true }; guard scheme == "http" else { return false }; return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.") }
    private func saveKey() { let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { keyStatus = "An empty key was not saved."; return }; do { try KeychainStore.save(trimmed); elevenLabsAPIKey = trimmed; cloudRegistry.registerElevenLabs(); keyStatus = "Saved securely." } catch { keyStatus = "Could not save the key." } }
    private func deleteKey() { do { try KeychainStore.delete(); cloudRegistry.unregister(CloudTranscriptionProvider.elevenLabs.id); elevenLabsAPIKey = ""; apiKeyDraft = ""; keyStatus = "Deleted." } catch { keyStatus = "Could not delete the Keychain credential." } }
    private func addPerson() { let name = newPerson.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }; if people.contains(where: { IgnoredSegmentRule.normalize($0.displayName) == IgnoredSegmentRule.normalize(name) }) { peopleStatus = "A person with that name already exists."; return }; peopleStatus = ""; people.append(PersonProfile(displayName: name, color: SpeakerColor.forSpeaker(atIndex: people.count), isYou: people.isEmpty)); newPerson = ""; persistPeople() }
    private func setYou(personID: UUID, value: Bool) { guard value else { return }; for i in people.indices { people[i].isYou = people[i].id == personID }; persistPeople() }
    private func persistPeople() { try? SettingsStore<PersonProfile>(filename: "People.json").save(people) }
    private func normalizePeople() { if people.filter(\.isYou).count > 1 { var found = false; for i in people.indices where people[i].isYou { if found { people[i].isYou = false } else { found = true } }; persistPeople() }; if !people.isEmpty && !people.contains(where: { $0.isYou }) { people[0].isYou = true; persistPeople() } }
    private func addRule() { rules.append(IgnoredSegmentRule(text: newRule)); newRule = ""; persistRules() }
    private func persistRules() { try? SettingsStore<IgnoredSegmentRule>(filename: "IgnoredSegments.json").save(rules) }
    private func addDeepSeek() { services.append(AIServiceProfile(name: "DeepSeek", baseURL: "https://api.deepseek.com", modelID: "deepseek-chat")); try? SettingsStore<AIServiceProfile>(filename: "AIServices.json").save(services) }
    private func addService() { let service = AIServiceProfile(name: newService, baseURL: "https://api.openai.com/v1", modelID: "gpt-4o-mini"); services.append(service); newService = ""; try? SettingsStore<AIServiceProfile>(filename: "AIServices.json").save(services) }
    private func updateService(_ service: AIServiceProfile, enabled: Bool) { guard let i = services.firstIndex(where: { $0.id == service.id }) else { return }; services[i].enabled = enabled; try? SettingsStore<AIServiceProfile>(filename: "AIServices.json").save(services) }
}

private extension SpeakerColor { var swiftUIColor: Color { switch self { case .blue: return .blue; case .orange: return .orange; case .green: return .green; case .purple: return .purple; case .pink: return .pink; case .teal: return .teal; case .indigo: return .indigo; case .brown: return .brown; case .red: return .red; case .burgundy: return .pink } } }
