import SwiftUI

/// Editable capture surface shown when dictation had no editable target. The text
/// is pre-filled with the transcript; the user can keep editing by keyboard.
/// `onCopyClose` receives the CURRENT (possibly edited) text; `onDiscard` closes
/// without writing the clipboard.
struct VoiceScratchpadView: View {
    @State private var text: String
    let onCopyClose: (String) -> Void
    let onDiscard: () -> Void

    init(text: String,
         onCopyClose: @escaping (String) -> Void,
         onDiscard: @escaping () -> Void) {
        _text = State(initialValue: text)
        self.onCopyClose = onCopyClose
        self.onDiscard = onDiscard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No editable field — dictation captured here")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 360, minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button(role: .cancel) {
                    onDiscard()
                } label: {
                    Text("Discard")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onCopyClose(text)
                } label: {
                    Text("Copy & Close")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
