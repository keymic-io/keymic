import AppKit
import SwiftUI

/// Settings tab for configuring the agent (endpoint/key/model + run tunables)
/// and a minimal debug chat for end-to-end testing without leaving Settings.
struct AgentSettingsTab: View {
    let agentRunner: AgentRunner
    let toolRegistry: ToolRegistry

    @State private var baseURL: String = UserDefaults.standard.string(forKey: "agentAPIBaseURL") ?? ""
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "agentAPIKey") ?? ""
    @State private var model: String = UserDefaults.standard.string(forKey: "agentModel") ?? ""
    @State private var maxSteps: Int = UserDefaults.standard.object(forKey: "agentMaxSteps") as? Int ?? 10
    @State private var maxWallTime: Int = UserDefaults.standard.object(forKey: "agentMaxWallTime") as? Int ?? 120
    @State private var toolTimeout: Int = UserDefaults.standard.object(forKey: "agentToolTimeout") as? Int ?? 30

    @State private var systemPrompt: String = ""
    @State private var userMessage: String = ""
    @State private var transcript: String = ""
    @State private var allToolNames: [String] = []
    @State private var selectedTools: Set<String> = []

    @State private var history: [AgentMessage] = []
    @State private var currentTask: Task<Void, Never>? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Text("Endpoint")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Base URL", text: $baseURL, onCommit: { save("agentAPIBaseURL", baseURL) })
                        SecureField("API Key", text: $apiKey, onCommit: { save("agentAPIKey", apiKey) })
                        TextField("Model", text: $model, onCommit: { save("agentModel", model) })
                    }.padding(8)
                }

                GroupBox(label: Text("Limits")) {
                    HStack {
                        Stepper(value: $maxSteps, in: 1...50) { Text("Max steps: \(maxSteps)") }
                            .onChange(of: maxSteps) { _, newValue in UserDefaults.standard.set(newValue, forKey: "agentMaxSteps") }
                        Stepper(value: $maxWallTime, in: 10...600, step: 10) { Text("Max wall time: \(maxWallTime)s") }
                            .onChange(of: maxWallTime) { _, newValue in UserDefaults.standard.set(newValue, forKey: "agentMaxWallTime") }
                        Stepper(value: $toolTimeout, in: 1...300, step: 1) { Text("Tool timeout: \(toolTimeout)s") }
                            .onChange(of: toolTimeout) { _, newValue in UserDefaults.standard.set(newValue, forKey: "agentToolTimeout") }
                    }.padding(8)
                }

                GroupBox(label: Text("Tools")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Empty selection = all tools available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(allToolNames, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { selectedTools.contains(name) },
                                set: { on in
                                    if on { selectedTools.insert(name) } else { selectedTools.remove(name) }
                                }
                            ))
                        }
                    }.padding(8)
                }
                .onAppear { refreshTools() }

                GroupBox(label: Text("Debug chat")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("System prompt (optional)", text: $systemPrompt, axis: .vertical)
                            .lineLimit(3...6)
                        TextField("Your message", text: $userMessage, axis: .vertical)
                            .lineLimit(2...8)
                        HStack {
                            Button("Run") { runOnce() }
                                .disabled(userMessage.isEmpty || currentTask != nil)
                            Button("Cancel") { currentTask?.cancel(); currentTask = nil }
                                .disabled(currentTask == nil)
                            Button("Clear history") { history.removeAll(); transcript = "" }
                        }
                        ScrollView { Text(transcript).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                            .frame(minHeight: 200)
                    }.padding(8)
                }
            }
            .padding(16)
        }
    }

    private func save(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func refreshTools() {
        Task {
            let names = await toolRegistry.allNames()
            await MainActor.run { allToolNames = names }
        }
    }

    private func runOnce() {
        let prompt = userMessage
        userMessage = ""
        let allowed: Set<String>? = selectedTools.isEmpty ? nil : selectedTools
        let options = AgentRunOptions(
            maxSteps: maxSteps,
            maxWallTime: TimeInterval(maxWallTime),
            toolTimeout: TimeInterval(toolTimeout),
            requestTimeout: 60
        )

        let sink = TranscriptCollector { fragment in
            Task { @MainActor in self.transcript += fragment }
        }
        let priorMessages = history

        currentTask = agentRunner.runForSettings(
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            userMessage: prompt,
            allowedToolNames: allowed,
            priorMessages: priorMessages,
            options: options,
            sink: sink
        )
        Task {
            _ = await currentTask?.value
            await MainActor.run {
                currentTask = nil
                // Append final assistant turn to history for multi-turn continuity.
                history.append(.user(prompt))
                if let lastAssistantText = sink.lastAssistantText {
                    history.append(.assistant(content: lastAssistantText))
                }
            }
        }
    }
}

/// Lightweight sink that streams human-readable lines into a callback and
/// remembers the last assistant text for history accumulation.
final class TranscriptCollector: AgentEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private let append: @Sendable (String) -> Void
    private(set) var lastAssistantText: String?

    init(append: @escaping @Sendable (String) -> Void) { self.append = append }

    func receive(_ event: AgentEvent) async {
        let line: String
        switch event {
        case .step(let i):
            line = "[step \(i)]\n"
        case .assistantMessage(let s):
            lock.lock(); lastAssistantText = s; lock.unlock()
            line = "assistant: \(s)\n"
        case .toolCall(let name, let args):
            let preview = String(data: args, encoding: .utf8) ?? "<binary>"
            line = "→ \(name) \(preview)\n"
        case .toolResult(let name, let output, let isError):
            let marker = isError ? "✗" : "←"
            line = "\(marker) \(name): \(output)\n"
        case .done:
            line = "[done]\n\n"
        case .error(let err):
            line = "[error: \(err.localizedDescription)]\n\n"
        }
        append(line)
    }
}
