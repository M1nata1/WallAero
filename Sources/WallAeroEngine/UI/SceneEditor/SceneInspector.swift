import AppKit
import SwiftUI
import WallpaperCore

/// The right-hand side of the editor: the properties of the selected layer or variable, or of
/// the background when neither is selected.
struct SceneInspector: View {
    @ObservedObject var model: SceneEditorModel

    var body: some View {
        Form {
            if let id = model.selection, let layer = model.binding(for: id) {
                LayerInspector(layer: layer, model: model)
            } else if let id = model.selection, let variable = model.variableBinding(for: id) {
                VariableInspector(variable: variable, model: model)
            } else {
                BackgroundInspector(background: $model.scene.background, model: model)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Background

private struct BackgroundInspector: View {
    @Binding var background: WallpaperScene.Background
    let model: SceneEditorModel

    var body: some View {
        Section("Background") {
            Picker("Kind", selection: kind) {
                Text("Video").tag(WallpaperScene.Background.Kind.video)
                Text("Image").tag(WallpaperScene.Background.Kind.image)
                Text("Color").tag(WallpaperScene.Background.Kind.color)
            }
            if background.kind != .color {
                LabeledContent("File") {
                    HStack(spacing: 8) {
                        Text(fileName(background.source))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { model.chooseBackground(background.kind) }
                    }
                }
                Picker("Scaling", selection: $background.fit) {
                    Text("Fill Screen").tag(WallpaperScene.Background.Fit.cover)
                    Text("Fit to Screen").tag(WallpaperScene.Background.Fit.contain)
                    Text("Stretch").tag(WallpaperScene.Background.Fit.fill)
                }
                if background.fit == .cover {
                    NumberRow("Position", value: $background.position, in: 0...100, suffix: "%")
                }
            }
            ColorRow("Color", hex: $background.color)
        }
        if background.kind != .color {
            Section("Adjustments") {
                NumberRow("Blur", value: $background.blur, in: 0...60)
                NumberRow("Brightness", value: $background.brightness, in: 0...200, suffix: "%")
                NumberRow("Contrast", value: $background.contrast, in: 0...200, suffix: "%")
                NumberRow("Saturation", value: $background.saturation, in: 0...200, suffix: "%")
                NumberRow("Hue", value: $background.hue, in: -180...180, suffix: "°")
            }
        }
    }

    /// Switching to video or picture needs a file; without one the choice does not stick.
    private var kind: Binding<WallpaperScene.Background.Kind> {
        Binding(
            get: { background.kind },
            set: { newKind in
                if newKind == .color || (newKind == background.kind && background.source != nil) {
                    background.kind = newKind
                } else {
                    model.chooseBackground(newKind)
                }
            }
        )
    }
}

// MARK: - Layer

private struct LayerInspector: View {
    @Binding var layer: WallpaperScene.Layer
    let model: SceneEditorModel

    var body: some View {
        Section("Layer") {
            TextField("Name", text: $layer.name)
            Toggle("Visible", isOn: $layer.isVisible)
            Toggle("Show on Lock Screen", isOn: $layer.showsOnLockScreen)
                .disabled(!layer.isVisible)
        }
        content
        Section("Position") {
            NumberRow("X", value: $layer.x, in: -20...120, suffix: "%")
            NumberRow("Y", value: $layer.y, in: -20...120, suffix: "%")
            NumberRow("Width", value: $layer.width, in: 1...150, suffix: "%")
            if layer.kind == .shape || layer.kind == .code {
                NumberRow("Height", value: $layer.height, in: 1...150, suffix: "%")
            }
            NumberRow("Rotation", value: $layer.rotation, in: -180...180, suffix: "°")
        }
        Section("Appearance") {
            NumberRow("Opacity", value: $layer.opacity, in: 0...100, suffix: "%")
            Picker("Blending", selection: $layer.blendMode) {
                ForEach(Self.blendModes, id: \.self) { mode in
                    Text(LocalizedStringKey("blend." + mode)).tag(mode)
                }
            }
            // Spelled out: `$layer.animation` would be Binding's own `animation(_:)` method.
            Picker("Animation", selection: $layer[dynamicMember: \.animation]) {
                ForEach(Self.animations, id: \.self) { animation in
                    Text(LocalizedStringKey("animation." + animation)).tag(animation)
                }
            }
            if layer.animation != "none" {
                NumberRow("Duration", value: $layer.animationDuration, in: 0.2...30, step: 0.1,
                          suffix: NSLocalizedString("seconds.short", comment: "Unit after a number of seconds"))
            }
        }
        Section("Shadow") {
            NumberRow("Blur", value: $layer.shadowBlur, in: 0...120)
            ColorRow("Color", hex: $layer.shadowColor)
            NumberRow("Offset X", value: $layer.shadowX, in: -100...100)
            NumberRow("Offset Y", value: $layer.shadowY, in: -100...100)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layer.kind {
        case .text:
            Section("Text") {
                TextEditor(text: $layer.text)
                    .font(.body)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                Menu("Insert") {
                    Button("Time") { layer.text += "{HH}:{mm}" }
                    Button("Time with Seconds") { layer.text += "{HH}:{mm}:{ss}" }
                    Button("Date") { layer.text += "{date}" }
                    Button("Weekday") { layer.text += "{weekday}" }
                    Button("Year") { layer.text += "{year}" }
                }
                .fixedSize()
            }
            Section("Font") {
                Picker("Font", selection: $layer.fontFamily) {
                    Text("System").tag("-apple-system")
                    Divider()
                    ForEach(Self.fontFamilies(including: layer.fontFamily), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                NumberRow("Size", value: $layer.fontSize, in: 0.5...60, step: 0.1, suffix: "%")
                Picker("Weight", selection: $layer.fontWeight) {
                    ForEach(Self.fontWeights, id: \.value) { weight in
                        Text(LocalizedStringKey(weight.name)).tag(weight.value)
                    }
                }
                Toggle("Italic", isOn: $layer.isItalic)
                ColorRow("Color", hex: $layer.color)
                Picker("Alignment", selection: $layer.alignment) {
                    Image(systemName: "text.alignleft").tag("left")
                    Image(systemName: "text.aligncenter").tag("center")
                    Image(systemName: "text.alignright").tag("right")
                }
                .pickerStyle(.segmented)
                NumberRow("Letter Spacing", value: $layer.letterSpacing, in: -0.2...1, step: 0.01)
                NumberRow("Line Height", value: $layer.lineHeight, in: 0.6...3, step: 0.05)
            }
        case .image:
            Section("Image") {
                LabeledContent("File") {
                    HStack(spacing: 8) {
                        Text(fileName(layer.source))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            if let source = model.chooseMedia(types: [.image]) {
                                layer.source = source
                            }
                        }
                    }
                }
            }
        case .shape:
            Section("Shape") {
                Picker("Shape", selection: $layer.shape) {
                    Text("Rectangle").tag("rectangle")
                    Text("Ellipse").tag("ellipse")
                }
                ColorRow("Fill", hex: $layer.fill)
                if layer.shape != "ellipse" {
                    NumberRow("Corner Radius", value: $layer.cornerRadius, in: 0...300)
                }
                NumberRow("Border Width", value: $layer.borderWidth, in: 0...40, step: 0.5)
                ColorRow("Border", hex: $layer.borderColor)
            }
        case .code:
            Section("Code") {
                CodeField(title: "HTML", text: $layer.html)
                CodeField(title: "CSS", text: $layer.css)
                CodeField(title: "JavaScript", text: $layer.javaScript)
            }
        }
    }

    static let blendModes = ["normal", "multiply", "screen", "overlay", "soft-light", "hard-light",
                             "color-dodge", "difference", "plus-lighter"]
    static let animations = ["none", "pulse", "float", "spin", "blink"]
    static let fontWeights: [(value: Int, name: String)] = [
        (100, "Thin"), (200, "Extra Light"), (300, "Light"), (400, "Regular"), (500, "Medium"),
        (600, "Semibold"), (700, "Bold"), (800, "Heavy"), (900, "Black"),
    ]

    /// The fonts installed on this Mac, plus the layer's own if the scene came from another one.
    static func fontFamilies(including current: String) -> [String] {
        var families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        if current != "-apple-system", !families.contains(current) {
            families.insert(current, at: 0)
        }
        return families
    }
}

private func fileName(_ source: String?) -> String {
    guard let source, !source.isEmpty else {
        return NSLocalizedString("No file chosen", comment: "Scene editor")
    }
    return (source as NSString).lastPathComponent
}

// MARK: - Rows

/// A number with a slider for coarse changes and a field for exact ones.
struct NumberRow: View {
    let title: Text
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    init(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, suffix: String = "") {
        self.init(title: Text(title), value: value, in: range, step: step, suffix: suffix)
    }

    /// With a title that is shown as it is: the user's own name for something.
    init(title: Text, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, suffix: String = "") {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.suffix = suffix
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Slider(value: stepped, in: range)
                    .frame(minWidth: 56)
                TextField("", value: stepped, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .leading)
            }
        } label: {
            title
        }
    }

    /// Keeps the number on the row's step and inside its range, whichever control sets it.
    /// A value dragged in the preview may lie between steps; it is shown as it is.
    private var stepped: Binding<Double> {
        Binding(
            get: { value },
            set: { value = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }
        )
    }
}

/// A colour kept as CSS text, such as "#FFAA00" or, with transparency, "#FFAA0080".
struct ColorRow: View {
    let title: Text
    @Binding var hex: String

    init(_ title: LocalizedStringKey, hex: Binding<String>) {
        self.init(title: Text(title), hex: hex)
    }

    init(title: Text, hex: Binding<String>) {
        self.title = title
        _hex = hex
    }

    var body: some View {
        ColorPicker(selection: Binding(
            get: { Color(nsColor: NSColor(cssHex: hex) ?? .white) },
            set: { hex = NSColor($0).cssHex }
        ), supportsOpacity: true) {
            title
        }
    }
}

private struct CodeField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .autocorrectionDisabled()
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

// MARK: - Colours

extension NSColor {
    /// Reads "#RGB", "#RRGGBB" and "#RRGGBBAA".
    convenience init?(cssHex text: String) {
        var digits = text.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6 || digits.count == 8, let number = UInt64(digits, radix: 16) else { return nil }
        let value = digits.count == 6 ? (number << 8) | 0xFF : number
        self.init(srgbRed: CGFloat((value >> 24) & 0xFF) / 255, green: CGFloat((value >> 16) & 0xFF) / 255,
                  blue: CGFloat((value >> 8) & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255)
    }

    var cssHex: String {
        guard let color = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
        return color.alphaComponent >= 0.999 ? rgb : rgb + String(format: "%02X", byte(color.alphaComponent))
    }
}
