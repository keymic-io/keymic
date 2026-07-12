import AppKit
import SwiftUI

private enum InjectionStrategyKind: String, CaseIterable, Identifiable {
    case replaceFocusedText
    case replaceSelection
    case clipboard
    case openURL
    case runShell
    case writeToITermPane

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .replaceFocusedText: return String(localized: "Replace focused text (paste)")
        case .replaceSelection:   return String(localized: "Replace selection (AX)")
        case .clipboard:          return String(localized: "Copy to clipboard")
        case .openURL:            return String(localized: "Open URL")
        case .runShell:           return String(localized: "Run shell command")
        case .writeToITermPane:   return String(localized: "Write to iTerm pane")
        }
    }

    init(_ strategy: InjectionStrategy) {
        switch strategy {
        case .replaceFocusedText: self = .replaceFocusedText
        case .replaceSelection:   self = .replaceSelection
        case .clipboard:          self = .clipboard
        case .openURL:            self = .openURL
        case .runShell:           self = .runShell
        case .writeToITermPane:   self = .writeToITermPane
        }
    }

    /// Produce a fresh `InjectionStrategy` with sensible defaults when the picker
    /// switches arms. Existing associated values are LOST when switching arms — by design.
    func defaultStrategy() -> InjectionStrategy {
        switch self {
        case .replaceFocusedText: return .replaceFocusedText
        case .replaceSelection:   return .replaceSelection
        case .clipboard:          return .clipboard
        case .openURL:            return .openURL(template: "https://www.google.com/search?q={query}")
        case .runShell:           return .runShell(commandTemplate: "{query}")
        case .writeToITermPane:   return .writeToITermPane(paneIndex: 0)
        }
    }
}


// MARK: - Root view

struct PersonasView: View {
    @StateObject private var model = PersonasViewModel()

    var body: some View {
        HSplitView {
            // Left: persona list
            VStack(spacing: 0) {
                List(selection: $model.selectedId) {
                    ForEach(model.personas) { persona in
                        PersonaRow(persona: persona, isActive: persona.id == model.activeId)
                            .tag(persona.id as String?)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 4) {
                    Button { model.addCustom() } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add persona")

                    Button { model.duplicateSelected() } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.selected == nil)
                    .help("Duplicate selected")

                    Button { model.deleteSelected() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canDeleteSelected)
                    .help("Delete selected")

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 140, idealWidth: 160, maxWidth: 185)

            // Right: detail form
            Group {
                if let selected = model.selected {
                    PersonaDetailForm(model: model, persona: selected)
                } else {
                    Text("Select a persona")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Row

private struct PersonaRow: View {
    let persona: Persona
    let isActive: Bool

    var body: some View {
        HStack {
            Image(systemName: persona.icon)
                .frame(width: 18)
            Text(persona.name)
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.small)
            } else if let cfg = persona.hotkey.flatMap(HotkeyConfig.parse) {
                Text(cfg.displayString())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Detail form

private struct PersonaDetailForm: View {
    @ObservedObject var model: PersonasViewModel
    let persona: Persona

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // Active controls
                HStack(spacing: 8) {
                    if model.activeId == persona.id {
                        Label("Default", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Set Default") { model.setActive(persona.id) }
                    }
                    if model.activeId != nil {
                        Button("Clear Default") { model.setActive(nil) }
                    }
                    Spacer()
                }

                Divider()

                // Name + Icon (same row)
                FieldLabel("Name") {
                    HStack(spacing: 10) {
                        PersonaIconPicker(
                            selection: model.binding(\.icon, for: persona),
                            showText: false
                        )

                        TextField("", text: model.binding(\.name, for: persona))
                            .disabled(persona.builtIn)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)

                        if persona.builtIn {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                        }
                    }
                }

                // Hotkey
                FieldLabel("Hotkey") {
                    PersonaHotkeyField(personaId: persona.id)
                }

                // Style prompt
                FieldLabel("Style Prompt") {
                    TextEditor(text: model.binding(\.stylePrompt, for: persona))
                        .font(.system(.body, design: .default))
                        .frame(minHeight: 150)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.25))
                        )
                }

                // Temperature
                FieldLabel("Temperature") {
                    HStack {
                        Slider(
                            value: model.binding(\.temperature, for: persona),
                            in: Persona.temperatureRange,
                            step: 0.05
                        )
                        Text(String(format: "%.2f", persona.temperature))
                            .frame(width: 40, alignment: .trailing)
                            .monospacedDigit()
                    }
                    // Preset chips
                    HStack(spacing: 6) {
                        ForEach([0.0, 0.3, 0.7, 1.0, 1.5], id: \.self) { preset in
                            Button(String(format: "%.1f", preset)) {
                                model.setTemperature(preset, for: persona)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }

                // Context sources (read-only label; multi-select editor is a follow-up)
                FieldLabel("Context") {
                    Text(contextSourcesDescription(persona.contextSources))
                        .foregroundStyle(.secondary)
                }

                // Output destination (injection strategy)
                FieldLabel("Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Strategy", selection: Binding<InjectionStrategyKind>(
                            get: { InjectionStrategyKind(persona.injectionStrategy) },
                            set: { newKind in
                                guard !persona.builtIn else { return }
                                model.setInjectionStrategy(newKind.defaultStrategy(), for: persona)
                            }
                        )) {
                            ForEach(InjectionStrategyKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .disabled(persona.builtIn)
                        .help(persona.builtIn
                              ? String(localized: "Built-in personas have a fixed output strategy.")
                              : String(localized: "Where to send the model's output."))

                        injectionStrategyEditor(for: persona)
                    }
                }

                if persona.builtIn {
                    Text("Built-in persona: name cannot be changed and cannot be deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func injectionStrategyEditor(for persona: Persona) -> some View {
        switch persona.injectionStrategy {
        case .openURL(let template):
            VStack(alignment: .leading, spacing: 4) {
                TextField("URL template", text: Binding<String>(
                    get: { template },
                    set: { new in
                        guard !persona.builtIn else { return }
                        model.setInjectionStrategy(.openURL(template: new), for: persona)
                    }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(persona.builtIn)
                Text("Placeholders: {query} {selection} {clipboard}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .runShell(let commandTemplate):
            VStack(alignment: .leading, spacing: 4) {
                TextField("Command template", text: Binding<String>(
                    get: { commandTemplate },
                    set: { new in
                        guard !persona.builtIn else { return }
                        model.setInjectionStrategy(.runShell(commandTemplate: new), for: persona)
                    }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(persona.builtIn)
                Text("Placeholders: {query} {selection} {clipboard}. A confirmation sheet shows on every run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .writeToITermPane(let paneIndex):
            HStack {
                Text("Pane index:")
                Stepper(value: Binding<Int>(
                    get: { paneIndex },
                    set: { new in
                        guard !persona.builtIn else { return }
                        let clamped = max(0, min(9, new))
                        model.setInjectionStrategy(.writeToITermPane(paneIndex: clamped), for: persona)
                    }), in: 0...9) {
                    Text("\(paneIndex)")
                        .frame(width: 24, alignment: .trailing)
                        .monospacedDigit()
                }
                .disabled(persona.builtIn)
                Spacer()
            }

        case .replaceFocusedText, .replaceSelection, .clipboard:
            EmptyView()
        }
    }

    private func contextSourcesDescription(_ sources: Set<ContextSource>) -> String {
        if sources.isEmpty { return String(localized: "None") }
        // Display in canonical enum order.
        let ordered = ContextSource.allCases.filter { sources.contains($0) }
        return ordered.map(\.displayName).joined(separator: ", ")
    }
}

private struct FieldLabel<Content: View>: View {
    let label: LocalizedStringKey
    let content: () -> Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Icon picker

struct PersonaIconPicker: View {
    @Binding var selection: String
    var showText: Bool = true
    @State private var showingGrid = false

    private let icons = [
        "sparkles", "globe", "terminal", "briefcase", "flame", "bolt",
        "crown", "antenna.radiowaves.left.and.right", "heart", "person.2",
        "chevron.left.forwardslash.chevron.right", "book", "mic", "pencil",
        "leaf", "star", "text.quote"
    ]

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 10), count: 5)

    var body: some View {
        Button {
            showingGrid.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection)
                    .font(.system(size: showText ? 14 : 17, weight: .medium))
                    .frame(width: 20, height: 20)
                if showText {
                    Text(selection)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, showText ? 0 : 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(showText ? 0 : 0.9))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingGrid, arrowEdge: .bottom) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(icons, id: \.self) { icon in
                    Button {
                        selection = icon
                        showingGrid = false
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(icon == selection ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(icon)
                }
            }
            .padding(12)
            .frame(width: 230)
        }
        .fixedSize()
    }
}

// MARK: - Hotkey field (wraps NSButton HotkeyRecorder)

struct PersonaHotkeyField: View {
    let personaId: String

    var body: some View {
        let raw = PersonaStore.shared.persona(id: personaId)?.hotkey

        return HStack(spacing: 4) {
            // .id(personaId): the embedded NSViewRepresentable captures personaId in
            // its validator and onCommit closures at makeNSView time. Without a
            // per-id identity, SwiftUI reuses the recorder across persona switches
            // and the closures keep targeting the originally selected persona —
            // recording for B would silently write to A and bypass cross-persona
            // conflict checks. The .id() forces SwiftUI to rebuild on switch.
            PersonaHotkeyRecorder(personaId: personaId)
                .id(personaId)
                .frame(height: 24)

            Button {
                PersonaStore.shared.setHotkey(nil, personaId: personaId)
                AppDelegate.syncPersonaHotkeysToRegistry()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(raw != nil ? 1 : 0)
            .disabled(raw == nil)
            .accessibilityLabel("Clear hotkey")
            .help("Clear")
        }
    }
}

private struct PersonaHotkeyRecorder: NSViewRepresentable {
    let personaId: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> HotkeyRecorder {
        let initial = PersonaStore.shared.persona(id: personaId)?.hotkey.flatMap(HotkeyConfig.parse)
        let recorder = HotkeyRecorder(
            initial: initial,
            mode: .combo,
            validator: { [personaId] cfg in
                HotkeySettingsStore.shared.validationMessage(for: cfg, owner: .persona(personaId))
            },
            onCommit: { [personaId] cfg in
                DispatchQueue.main.async {
                    PersonaStore.shared.setHotkey(cfg.encode(), personaId: personaId)
                    AppDelegate.syncPersonaHotkeysToRegistry()
                }
            }
        )
        context.coordinator.recorder = recorder
        return recorder
    }

    func updateNSView(_ recorder: HotkeyRecorder, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recorder = recorder
        let cfg = PersonaStore.shared.persona(id: personaId)?.hotkey.flatMap(HotkeyConfig.parse)
        recorder.updateValue(cfg)
    }

    final class Coordinator {
        var parent: PersonaHotkeyRecorder
        weak var recorder: HotkeyRecorder?
        init(parent: PersonaHotkeyRecorder) { self.parent = parent }
    }
}

// MARK: - ViewModel

@MainActor
final class PersonasViewModel: ObservableObject {
    @Published var personas: [Persona] = []
    @Published var selectedId: String?
    @Published var activeId: String?

    private let store = PersonaStore.shared
    private var observer: NSObjectProtocol?

    init() {
        reload()
        if selectedId == nil { selectedId = personas.first?.id }
        observer = NotificationCenter.default.addObserver(
            forName: PersonaStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        personas = store.personas
        activeId = store.activePersonaId
        // Keep selection valid
        if let id = selectedId, !personas.contains(where: { $0.id == id }) {
            selectedId = personas.first?.id
        }
    }

    var selected: Persona? { personas.first { $0.id == selectedId } }
    var canDeleteSelected: Bool { selected.map { !$0.builtIn } ?? false }

    func setActive(_ id: String?) { store.setActive(id) }

    func addCustom() {
        let now = Date()
        let p = Persona(
            id: "user-\(UUID().uuidString.prefix(8))",
            name: "New Persona",
            icon: "sparkles",
            stylePrompt: "",
            temperature: 0.7,
            hotkey: nil,
            contextSources: [],
            builtIn: false,
            createdAt: now,
            updatedAt: now
        )
        store.add(p)
        selectedId = p.id
    }

    func duplicateSelected() {
        guard let id = selectedId, let dup = store.duplicate(id: id) else { return }
        selectedId = dup.id
    }

    func deleteSelected() {
        guard let id = selectedId else { return }
        store.delete(id: id)
        personas.removeAll { $0.id == id }
        selectedId = personas.first?.id
    }

    func setTemperature(_ value: Double, for persona: Persona) {
        guard var p = store.persona(id: persona.id) else { return }
        p.temperature = value
        store.update(p)
    }

    func setInjectionStrategy(_ strategy: InjectionStrategy, for persona: Persona) {
        guard !persona.builtIn else { return }
        guard var p = store.persona(id: persona.id) else { return }
        p.injectionStrategy = strategy
        store.update(p)
    }


    /// Binding that reads from the live personas array and calls store.update on set.
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<Persona, Value>, for persona: Persona) -> Binding<Value> {
        Binding(
            get: {
                (self.personas.first { $0.id == persona.id } ?? persona)[keyPath: keyPath]
            },
            set: { [weak self] newValue in
                guard let self,
                      var p = self.store.persona(id: persona.id),
                      p[keyPath: keyPath] != newValue else { return }
                p[keyPath: keyPath] = newValue
                self.store.update(p)
            }
        )
    }
}
