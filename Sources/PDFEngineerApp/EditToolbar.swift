import SwiftUI

/// The editing tool bar under the window toolbar: tools on the left, the
/// active tool's font or stroke settings on the right (like Acrobat's Edit bar).
struct EditToolbar: View {

    @ObservedObject var controller: AppController
    @ObservedObject var tools: ToolState

    init(controller: AppController) {
        self.controller = controller
        self.tools = controller.tools
    }

    private let groups: [[ToolState.Tool]] = [
        [.select],
        [.editText, .addText],
        [.highlight, .underline, .strikeOut],
        [.draw, .rectangle, .oval, .line, .arrow],
        [.note, .whiteOut, .sign],
    ]

    /// Which settings to show: those of the selected annotation, else of the tool.
    private var showsFont: Bool {
        tools.tool.usesFont || tools.selectedAnnotation?.annotation.object.type == "FreeText"
    }

    private var showsStroke: Bool {
        if tools.tool.usesStroke { return true }
        return ["Square", "Circle", "Line", "Ink"].contains(tools.selectedAnnotation?.annotation.object.type ?? "")
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().frame(height: 18) }
                HStack(spacing: 2) {
                    ForEach(group) { tool in toolButton(tool) }
                }
            }

            Spacer(minLength: 12)

            if showsFont { fontControls }
            if showsStroke { strokeControls }
            if tools.tool == .sign { signControls }
            if tools.selectedAnnotation != nil {
                Button(role: .destructive) { controller.deleteSelectedAnnotation() } label: {
                    Image(systemName: "trash")
                }
                .help("Delete the selected item (⌫)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: tools.fontFamily) { _, _ in controller.restyleSelectedText() }
        .onChange(of: tools.fontSize) { _, _ in controller.restyleSelectedText() }
        .onChange(of: tools.bold) { _, _ in controller.restyleSelectedText() }
        .onChange(of: tools.italic) { _, _ in controller.restyleSelectedText() }
        .onChange(of: tools.alignment) { _, _ in controller.restyleSelectedText() }
        .onChange(of: tools.textColor) { _, _ in controller.restyleSelectedText() }
        .onChange(of: tools.strokeColor) { _, _ in controller.restyleSelectedShape() }
        .onChange(of: tools.lineWidth) { _, _ in controller.restyleSelectedShape() }
        .onChange(of: tools.fillEnabled) { _, _ in controller.restyleSelectedShape() }
        .onChange(of: tools.fillColor) { _, _ in controller.restyleSelectedShape() }
    }

    private func toolButton(_ tool: ToolState.Tool) -> some View {
        let active = tools.tool == tool
        return Button {
            if tool == .sign && tools.pendingSignature == nil {
                controller.showingSignatureSheet = true
            }
            tools.tool = tool
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .help(tool.key.map { "\(tool.title) (\(String($0.character).uppercased()))" } ?? tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var fontControls: some View {
        HStack(spacing: 6) {
            Picker("Font", selection: $tools.fontFamily) {
                ForEach(ToolState.fontFamilies, id: \.self) { family in
                    Text(family).font(.custom(family, size: 12)).tag(family)
                }
                if !ToolState.fontFamilies.contains(tools.fontFamily) {
                    Text(tools.fontFamily).tag(tools.fontFamily)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            TextField("Size", value: $tools.fontSize, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Stepper("Size", value: $tools.fontSize, in: 4...200, step: 1).labelsHidden()

            Toggle(isOn: $tools.bold) { Image(systemName: "bold") }
                .toggleStyle(.button)
                .help("Bold")
            Toggle(isOn: $tools.italic) { Image(systemName: "italic") }
                .toggleStyle(.button)
                .help("Italic")

            Picker("Alignment", selection: $tools.alignment) {
                Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                Image(systemName: "text.alignright").tag(NSTextAlignment.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)

            ColorPicker("Text Colour", selection: $tools.textColor, supportsOpacity: false)
                .labelsHidden()
                .help("Text colour")
        }
    }

    private var strokeControls: some View {
        HStack(spacing: 6) {
            ColorPicker("Stroke", selection: $tools.strokeColor)
                .labelsHidden()
                .help("Line colour")
            Picker("Width", selection: $tools.lineWidth) {
                ForEach([1.0, 2, 3, 5, 8], id: \.self) { Text("\(Int($0)) pt").tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)
            .help("Line width")
            if tools.tool.usesFill || ["Square", "Circle"].contains(tools.selectedAnnotation?.annotation.object.type ?? "") {
                Toggle("Fill", isOn: $tools.fillEnabled).toggleStyle(.checkbox)
                ColorPicker("Fill", selection: $tools.fillColor)
                    .labelsHidden()
                    .disabled(!tools.fillEnabled)
                    .help("Fill colour")
            }
        }
    }

    private var signControls: some View {
        HStack(spacing: 6) {
            if let signature = tools.pendingSignature {
                Image(nsImage: signature)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 20)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            }
            Button(tools.pendingSignature == nil ? "Create Signature…" : "Change…") {
                controller.showingSignatureSheet = true
            }
        }
    }
}
