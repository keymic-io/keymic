import AppKit
import SwiftUI

struct SelectedTextEditorView: View {
    let controller: SelectedTextEditorController

    @Bindable private var state: SelectedTextEditorState
    @FocusState private var instructionFocused: Bool

    init(controller: SelectedTextEditorController) {
        self.controller = controller
        self.state = controller.state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chipRow
            instructionRow
            footer
            statusRow
        }
        .padding(14)
        .frame(width: 420, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear { instructionFocused = true }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(state.selectionPreview.isEmpty
                 ? String(localized: "(no selection)")
                 : state.selectionPreview)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(state.selectionFullText)
            Spacer(minLength: 0)
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EditorAction.allCases) { action in
                    chipButton(for: action)
                }
            }
        }
    }

    private func chipButton(for action: EditorAction) -> some View {
        let isSelected = state.selectedAction == action
        return Button {
            state.selectedAction = action
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.sfSymbol).font(.system(size: 11))
                Text(action.displayName).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.9) : Color.gray.opacity(0.18))
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(state.isRunning)
    }

    private var instructionRow: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "Type, or hold ⏺ to speak"),
                text: $state.instructionText,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .focused($instructionFocused)
            .lineLimit(1...4)
            .onSubmit { Task { await controller.apply() } }
            .disabled(state.isRunning)
            voiceButton
        }
    }

    private var voiceButton: some View {
        ZStack {
            Circle()
                .fill(state.isRecording ? Color.red.opacity(0.9) : Color.gray.opacity(0.2))
                .frame(width: 32, height: 32)
            Image(systemName: state.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.isRecording ? Color.white : Color.primary)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !state.isRecording && !state.isRunning {
                        controller.startVoice()
                    }
                }
                .onEnded { _ in
                    if state.isRecording {
                        controller.stopVoice()
                    }
                }
        )
        .help(String(localized: "Hold to speak"))
        .disabled(state.isRunning)
    }

    private var footer: some View {
        HStack {
            if state.isRunning {
                ProgressView().controlSize(.small)
                Text(String(localized: "Rewriting…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.close()
            } label: {
                Text(String(localized: "Cancel"))
                    .frame(minWidth: 60)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(state.isRunning)

            Button {
                Task { await controller.apply() }
            } label: {
                Text(String(localized: "Apply"))
                    .frame(minWidth: 60)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(applyDisabled)
        }
    }

    private var applyDisabled: Bool {
        if state.isRunning { return true }
        if state.selectedAction == .freeForm
            && state.instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    @ViewBuilder
    private var statusRow: some View {
        if let err = state.errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if let status = state.statusMessage {
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let result = state.result, state.routeResult != nil {
            ScrollView {
                Text(result)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 100)
        }
    }
}
