import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case cloud = "Cloud Transcription"
    case local = "Local Transcription"
    case people = "People"
    case ignored = "Ignored Segments"
    case ai = "AI Services"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cloud: return "cloud"
        case .local: return "desktopcomputer"
        case .people: return "person.2"
        case .ignored: return "eye.slash"
        case .ai: return "sparkles"
        }
    }
}

struct SettingsView: View {

    @Binding var elevenLabsAPIKey: String

    @StateObject private var cloudRegistry = CloudTranscriptionRegistry.shared

    // `@StateObject`, not `@State`, and the difference is not academic: a
    // `@State` default value is an ordinary expression, evaluated every time
    // the view struct is created even though SwiftUI keeps only the first
    // result. These three lines used to read and decode three JSON files on
    // every single redraw of the window. `@StateObject` takes an autoclosure
    // and evaluates it once.
    @StateObject private var people = SharedSettings.people
    @StateObject private var rules = SharedSettings.ignoredSegments

    @State private var category: SettingsCategory = .cloud
    @State private var apiKeyDraft = ""
    @State private var keyVisible = false
    @State private var keyStatus = ""
    @State private var confirmDeleteKey = false
    // AI services keep an explicit Save, so they stay plain state: a base URL
    // is something you finish typing and confirm, and saving it keystroke by
    // keystroke would persist half-written addresses that the endpoint check
    // is there to refuse.
    @State private var services: [AIServiceProfile] = []
    @State private var aiKeys: [UUID: String] = [:]
    @State private var visibleAIKey: UUID?
    @State private var newPerson = ""
    @State private var peopleStatus = ""
    @State private var newRule = ""
    @State private var newService = ""
    @State private var serviceStatus = ""

    private let rose = Color(red: 0.72, green: 0.40, blue: 0.44)
    private let servicesStore = SettingsStore<AIServiceProfile>(filename: "AIServices.json")

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings")
                    .font(.title3.bold())
                    .padding(.bottom, 10)
                ForEach(SettingsCategory.allCases) { item in
                    Button { category = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(category == item ? rose.opacity(0.16) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(20)
            .frame(width: 205)
            .background(.quaternary.opacity(0.25))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(category.rawValue).font(.largeTitle.bold())
                    pane
                }
                .padding(32)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            normalizePeople()
            loadKey()
            services = servicesStore.load()
            for service in services {
                aiKeys[service.id] = (try? KeychainStore.read(account: service.id.uuidString)) ?? ""
            }
        }
        // Edits are written on a delay, so leaving the pane within that delay
        // must not lose the last thing typed.
        .onDisappear {
            people.flush()
            rules.flush()
        }
        .alert("Delete ElevenLabs key?", isPresented: $confirmDeleteKey) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteKey() }
        } message: {
            Text("This removes the credential and unregisters ElevenLabs from the picker.")
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch category {
        case .cloud: cloudPane
        case .local: localPane
        case .people: peoplePane
        case .ignored: ignoredPane
        case .ai: aiPane
        }
    }

    // MARK: Cloud

    private var cloudPane: some View {
        GroupBox("ElevenLabs") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your key is stored in the macOS Keychain and is never logged.")
                    .foregroundStyle(.secondary)
                HStack {
                    if keyVisible {
                        TextField("API key", text: $apiKeyDraft)
                    } else {
                        SecureField("API key", text: $apiKeyDraft)
                    }
                    Button(keyVisible ? "Hide" : "Reveal") { keyVisible.toggle() }
                    Button("Save") { saveKey() }
                    Button("Delete", role: .destructive) { confirmDeleteKey = true }
                }
                Toggle("Available in transcription engine", isOn: Binding(
                    get: {
                        cloudRegistry.providers
                            .first { $0.id == CloudTranscriptionProvider.elevenLabs.id }?.enabled ?? false
                    },
                    set: { enabled in
                        guard enabled else {
                            cloudRegistry.setEnabled(false, id: CloudTranscriptionProvider.elevenLabs.id)
                            return
                        }
                        // An engine that cannot run is worse than one that is
                        // simply absent from the picker.
                        let persisted = ((try? KeychainStore.read()) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if persisted.isEmpty {
                            keyStatus = "Save an API key before enabling ElevenLabs."
                        } else {
                            cloudRegistry.registerElevenLabs()
                        }
                    }))
                if let error = cloudRegistry.lastError {
                    Text("Could not persist provider settings: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !keyStatus.isEmpty {
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: Local

    private var localPane: some View {
        GroupBox("On-device transcription") {
            VStack(alignment: .leading, spacing: 10) {
                Label(LocalTranscriptionAvailability.isAvailable
                      ? "Apple Speech is available"
                      : "Apple Speech is unavailable",
                      systemImage: LocalTranscriptionAvailability.isAvailable
                      ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(LocalTranscriptionAvailability.isAvailable ? .green : .secondary)
                Text("Apple Speech uses locale assets installed by macOS; those assets are not Whisper model sizes.")
                    .foregroundStyle(.secondary)
                Text("Whisper Base and Whisper Small slots are reserved for a future local engine. No downloads are performed in this milestone.")
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    // MARK: People

    private var peoplePane: some View {
        GroupBox("People directory") {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Display name", text: $newPerson)
                    Button("Add") { addPerson() }
                        .disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !peopleStatus.isEmpty {
                    Text(peopleStatus).font(.caption).foregroundStyle(.red)
                }
                if let error = people.lastError {
                    Text("Could not save the People directory: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Binding straight into the document: a name edited here is
                // persisted by the document itself, which is the whole reason
                // renames are no longer lost on the way out of this pane.
                ForEach($people.values) { $person in
                    HStack {
                        Circle()
                            .fill(person.color.color)
                            .frame(width: 10, height: 10)
                        TextField("Name", text: $person.displayName)
                        Menu {
                            ForEach(SpeakerColor.allCases, id: \.self) { color in
                                Button(color.displayName) { person.color = color }
                            }
                        } label: {
                            Image(systemName: "paintpalette")
                        }
                        Toggle("You", isOn: Binding(get: { person.isYou },
                                                    set: { setYou(personID: person.id, value: $0) }))
                        Button(role: .destructive) { remove(person) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: Ignored segments

    private var ignoredPane: some View {
        GroupBox("Whole-segment rules") {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Exact segment to hide", text: $newRule)
                    Button("Add") { addRule() }
                        .disabled(newRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = rules.lastError {
                    Text("Could not save the rules: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ForEach($rules.values) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                        Text(rule.text)
                        Spacer()
                        Button(role: .destructive) {
                            rules.values.removeAll { $0.id == rule.id }
                            rules.save()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                Text("Matching is normalized and whole-segment only; longer sentences remain untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    // MARK: AI services

    private var aiPane: some View {
        GroupBox("Registered providers") {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Custom service name", text: $newService)
                    Button("Add DeepSeek") { addDeepSeek() }
                    Button("Add custom") { addService() }.disabled(newService.isEmpty)
                }
                if !serviceStatus.isEmpty {
                    Text(serviceStatus).font(.caption).foregroundStyle(.red)
                }
                if services.isEmpty {
                    Text("No AI services registered. Registration does not make paid requests.")
                        .foregroundStyle(.secondary)
                }
                ForEach(services) { service in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: "sparkles")
                            TextField("Name", text: serviceBinding(service.id, .name))
                            TextField("Base URL", text: serviceBinding(service.id, .baseURL))
                            TextField("Model", text: serviceBinding(service.id, .modelID))
                            Toggle("Enabled", isOn: Binding(get: { service.enabled },
                                                            set: { updateService(service, enabled: $0) }))
                                .labelsHidden()
                            Button("Save") { saveService(service.id) }
                            Button(role: .destructive) { removeService(service) } label: {
                                Image(systemName: "trash")
                            }
                        }
                        if service.baseURL.lowercased().hasPrefix("http://") {
                            Text("Local-network HTTP only; public HTTP endpoints are blocked.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            if visibleAIKey == service.id {
                                TextField("API key", text: keyBinding(for: service.id))
                            } else {
                                SecureField("API key", text: keyBinding(for: service.id))
                            }
                            Button(visibleAIKey == service.id ? "Hide" : "Reveal") {
                                visibleAIKey = visibleAIKey == service.id ? nil : service.id
                            }
                            Button("Save key") {
                                try? KeychainStore.save(aiKeys[service.id] ?? "",
                                                        account: service.id.uuidString)
                            }
                        }
                        .padding(.leading, 22)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: The ElevenLabs key

    private func loadKey() {
        apiKeyDraft = (try? KeychainStore.read()) ?? ""
    }

    private func saveKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyStatus = "An empty key was not saved."
            return
        }
        do {
            try KeychainStore.save(trimmed)
            elevenLabsAPIKey = trimmed
            cloudRegistry.registerElevenLabs()
            keyStatus = "Saved securely."
        } catch {
            keyStatus = "Could not save the key."
        }
    }

    private func deleteKey() {
        do {
            try KeychainStore.delete()
            cloudRegistry.unregister(CloudTranscriptionProvider.elevenLabs.id)
            elevenLabsAPIKey = ""
            apiKeyDraft = ""
            keyStatus = "Deleted."
        } catch {
            keyStatus = "Could not delete the Keychain credential."
        }
    }

    // MARK: People

    private func addPerson() {
        let name = newPerson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existing = people.values.contains {
            IgnoredSegmentRule.normalize($0.displayName) == IgnoredSegmentRule.normalize(name)
        }
        guard !existing else {
            peopleStatus = "A person with that name already exists."
            return
        }
        peopleStatus = ""
        people.values.append(PersonProfile(displayName: name,
                                           color: SpeakerColor.forSpeaker(atIndex: people.values.count),
                                           isYou: people.values.isEmpty))
        newPerson = ""
        // Structural edits are written at once rather than on the delay: they
        // are the ones it would be most annoying to lose.
        people.save()
    }

    private func remove(_ person: PersonProfile) {
        let wasYou = person.isYou
        people.values.removeAll { $0.id == person.id }
        if wasYou, !people.values.isEmpty {
            people.values[0].isYou = true
        }
        people.save()
    }

    /// Exactly one person is "You", and it is never nobody once the directory
    /// has anyone in it: the microphone track of a recording is labelled from
    /// this flag.
    private func setYou(personID: UUID, value: Bool) {
        guard value else { return }
        for index in people.values.indices {
            people.values[index].isYou = people.values[index].id == personID
        }
        people.save()
    }

    private func normalizePeople() {
        var changed = false
        if people.values.filter(\.isYou).count > 1 {
            var found = false
            for index in people.values.indices where people.values[index].isYou {
                if found { people.values[index].isYou = false } else { found = true }
            }
            changed = true
        }
        if !people.values.isEmpty && !people.values.contains(where: { $0.isYou }) {
            people.values[0].isYou = true
            changed = true
        }
        if changed { people.save() }
    }

    // MARK: Rules

    private func addRule() {
        rules.values.append(IgnoredSegmentRule(text: newRule))
        newRule = ""
        rules.save()
    }

    // MARK: AI services

    private enum ServiceField { case name, baseURL, modelID }

    private func serviceBinding(_ id: UUID, _ field: ServiceField) -> Binding<String> {
        Binding(get: {
            guard let service = services.first(where: { $0.id == id }) else { return "" }
            switch field {
            case .name: return service.name
            case .baseURL: return service.baseURL
            case .modelID: return service.modelID
            }
        }, set: {
            guard let index = services.firstIndex(where: { $0.id == id }) else { return }
            switch field {
            case .name: services[index].name = $0
            case .baseURL: services[index].baseURL = $0
            case .modelID: services[index].modelID = $0
            }
        })
    }

    private func saveService(_ id: UUID) {
        guard let service = services.first(where: { $0.id == id }) else { return }
        guard LocalEndpointPolicy.allows(service.baseURL) else {
            serviceStatus = "Invalid URL: use HTTPS, or HTTP on localhost/private network only."
            return
        }
        serviceStatus = ""
        try? servicesStore.save(services)
    }

    private func removeService(_ service: AIServiceProfile) {
        services.removeAll { $0.id == service.id }
        try? servicesStore.save(services)
        try? KeychainStore.delete(account: service.id.uuidString)
    }

    private func addDeepSeek() {
        services.append(AIServiceProfile(name: "DeepSeek",
                                         baseURL: "https://api.deepseek.com",
                                         modelID: "deepseek-chat"))
        try? servicesStore.save(services)
    }

    private func addService() {
        services.append(AIServiceProfile(name: newService,
                                         baseURL: "https://api.openai.com/v1",
                                         modelID: "gpt-4o-mini"))
        newService = ""
        try? servicesStore.save(services)
    }

    private func updateService(_ service: AIServiceProfile, enabled: Bool) {
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return }
        services[index].enabled = enabled
        try? servicesStore.save(services)
    }

    private func keyBinding(for id: UUID) -> Binding<String> {
        Binding(get: { aiKeys[id] ?? "" }, set: { aiKeys[id] = $0 })
    }
}
