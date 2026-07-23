import SwiftUI

/// Editable capture surface shown when dictation had no editable target. The text
/// is pre-filled with the transcript; the user can keep editing by keyboard.
/// `onCopyClose` receives the CURRENT (possibly edited) text; `onDiscard` closes
/// without writing the clipboard.
struct VoiceScratchpadView: View {
    @State private var text: String
    @FocusState private var editorFocused: Bool
    let onCopyClose: (String) -> Void
    let onDiscard: () -> Void

    init(text: String,
         onCopyClose: @escaping (String) -> Void,
         onDiscard: @escaping () -> Void) {
        _text = State(initialValue: text)
        self.onCopyClose = onCopyClose
        self.onDiscard = onDiscard
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No editable field — dictation captured here", systemImage: "text.cursor")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minWidth: 460, minHeight: 260)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .accessibilityLabel("Dictated text")

            HStack {
                Spacer()
                Button("Discard", role: .cancel) { onDiscard() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy & Close") { onCopyClose(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 340)
        // Defer to the next runloop so the window is key before we grab focus.
        .onAppear { DispatchQueue.main.async { editorFocused = true } }
    }
}
