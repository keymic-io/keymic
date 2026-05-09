import SwiftUI
import AppKit

/// WeChat-style two-row floating toolbar.
struct EditorToolbarView: View {
    @ObservedObject var state: EditorState

    private let drawingTools: [AnnotationTool] = [.rect, .ellipse, .arrow, .text, .highlight, .mosaic, .blur]
    private let swatches: [Color] = [.red, .orange, .yellow, .green, .blue, .black, .white]

    var body: some View {
        VStack(spacing: 6) {
            firstRow
            if state.selectedTool.isDrawingTool {
                Divider()
                secondRow
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
    }

    private var firstRow: some View {
        HStack(spacing: 4) {
            ForEach(drawingTools, id: \.self) { tool in
                toolButton(tool)
            }
            Divider().frame(height: 22)
            toolButton(.ocr)
            Divider().frame(height: 22)
            iconButton("arrow.uturn.backward", help: "Undo (⌘Z)", enabled: state.canUndo) { state.undoAction?() }
            iconButton("xmark", help: "Cancel (Esc)") { state.cancelAction?() }
            iconButton("square.and.arrow.down", help: "Save") { state.saveAction?() }
            iconButton("checkmark", help: "Confirm (Return)", tint: .accentColor) { state.confirmAction?() }
        }
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let selected = state.selectedTool == tool
        return Button(action: { state.selectedTool = tool }) {
            Image(systemName: tool.iconName)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("\(tool.displayName)")
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool = true, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .foregroundStyle(enabled ? tint : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var secondRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<swatches.count, id: \.self) { i in
                    let c = swatches[i]
                    Button(action: { state.selectedColor = c }) {
                        Circle()
                            .fill(c)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(state.selectedColor == c ? Color.accentColor : .gray.opacity(0.3), lineWidth: state.selectedColor == c ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 18)

            HStack(spacing: 4) {
                ForEach([CGFloat(2), 4, 6], id: \.self) { w in
                    let selected = state.lineWidth == w
                    Button(action: { state.lineWidth = w }) {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: w * 2 + 2, height: w * 2 + 2)
                            .padding(.horizontal, 4)
                            .background(selected ? Color.accentColor.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }

            if state.selectedTool == .text {
                Divider().frame(height: 18)
                Picker("", selection: $state.fontSize) {
                    ForEach([CGFloat(12), 14, 18, 24, 36], id: \.self) { s in
                        Text("\(Int(s))").tag(s)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 64)
            }
            if state.selectedTool == .rect {
                Divider().frame(height: 18)
                Toggle("Shadow", isOn: $state.dropShadowEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
        }
    }
}
