import SwiftUI
import AppKit

// MARK: - Top Bar

/// Horizontal bar displayed at the top of the editor window.
/// Layout: [Undo Redo Clear] ---- [Copy Save Share]
struct EditorTopBarView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 8) {
            // Left group
            HStack(spacing: 4) {
                Button(action: { state.undoAction?() }) {
                    Label("Undo", systemImage: "arrow.uturn.backward.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(!state.canUndo)
                .help("Undo")

                Button(action: { state.redoAction?() }) {
                    Label("Redo", systemImage: "arrow.uturn.forward.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(!state.canRedo)
                .help("Redo")

                Divider().frame(height: 20)

                Button(action: { state.clearAction?() }) {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("Clear all annotations")
            }

            Spacer()

            // Right group
            HStack(spacing: 4) {
                Button(action: { state.copyAction?() }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy to clipboard")

                Button(action: { state.saveAction?() }) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .help("Save to file")

                Divider().frame(height: 20)

                Button(action: {
                    let anchor = NSApp.keyWindow?.contentView ?? NSView()
                    state.shareAction?(anchor, .zero)
                }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share  (share picker anchors to window — v1 limitation)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Tool Sidebar

/// Vertical sidebar displayed on the left edge of the editor window.
/// Width: 96pt. Contains tool selector + property controls.
struct EditorToolSidebarView: View {
    @ObservedObject var state: EditorState

    // Fixed colour swatches
    private let swatches: [Color] = [.red, .orange, .yellow, .green, .blue, .black, .white]

    // Line width segments
    private let lineWidths: [(label: String, value: CGFloat)] = [
        ("Thin", 2), ("Med", 4), ("Thick", 6)
    ]

    // Font size options
    private let fontSizes: [CGFloat] = [12, 14, 18, 24, 36]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                toolList
                Divider()
                propertyPanel
            }
        }
        .frame(width: 96)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) {
            Divider()
        }
    }

    // MARK: Tool Buttons

    private var toolList: some View {
        VStack(spacing: 2) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                ToolButton(tool: tool, isSelected: state.selectedTool == tool) {
                    state.selectedTool = tool
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Property Panel

    private var propertyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            colorSwatches
            lineWidthControl
            fontSizeControl
            dropShadowToggle
        }
        .padding(8)
    }

    // Colour swatch grid (2 columns)
    private var colorSwatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Color")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 22, maximum: 22), spacing: 4)], spacing: 4) {
                ForEach(swatches, id: \.self) { swatch in
                    Circle()
                        .fill(swatch)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if state.selectedColor == swatch {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .shadow(radius: 1)
                            }
                        }
                        .onTapGesture { state.selectedColor = swatch }
                }
            }
        }
    }

    // Line-width segmented control (3 fixed steps)
    private var lineWidthControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Width")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 1) {
                ForEach(lineWidths, id: \.label) { seg in
                    let isActive = state.lineWidth == seg.value
                    Button(seg.label) {
                        state.lineWidth = seg.value
                    }
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(isActive ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(isActive ? Color.white : Color.primary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .buttonStyle(.plain)
        }
    }

    // Font-size picker (only active for Text tool)
    private var fontSizeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Font Size")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("", selection: $state.fontSize) {
                ForEach(fontSizes, id: \.self) { size in
                    Text("\(Int(size))pt").tag(size)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(state.selectedTool != .text)
        }
    }

    // Drop-shadow toggle (only active for Rect tool)
    private var dropShadowToggle: some View {
        Toggle("Drop Shadow", isOn: $state.dropShadowEnabled)
            .font(.caption2)
            .toggleStyle(.switch)
            .disabled(state.selectedTool != .rect)
    }
}

// MARK: - Tool Button

private struct ToolButton: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    // Keyboard hint for each tool
    private var shortcutHint: String {
        switch tool {
        case .select:    return "V"
        case .arrow:     return "A"
        case .rect:      return "R"
        case .ellipse:   return "E"
        case .text:      return "T"
        case .highlight: return "H"
        case .mosaic:    return "P"
        case .blur:      return "B"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 16))
                Text(tool.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(shortcutHint)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 80, height: 54)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.2)
                    : Color.clear
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("\(tool.displayName) (\(shortcutHint))")
    }
}

// MARK: - Previews

#if DEBUG
struct EditorTopBarView_Previews: PreviewProvider {
    static var previews: some View {
        let state = EditorState()
        state.canUndo = true
        return EditorTopBarView(state: state)
            .frame(width: 600)
    }
}

struct EditorToolSidebarView_Previews: PreviewProvider {
    static var previews: some View {
        EditorToolSidebarView(state: EditorState())
            .frame(height: 600)
    }
}
#endif
