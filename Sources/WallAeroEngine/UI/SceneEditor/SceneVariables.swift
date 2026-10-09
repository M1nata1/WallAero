import AppKit
import SwiftUI
import WallpaperCore

/// The control that sets a variable's value, by its kind. The editor shows it, and so do the
/// wallpaper's settings in the main window: that is what a variable is for.
struct VariableValueRow: View {
    @Binding var variable: WallpaperScene.Variable
    /// What the row is called; the wallpaper's settings pass the variable's own title.
    let title: Text

    var body: some View {
        switch variable.kind {
        case .color:
            ColorRow(title: title, hex: $variable.color)
        case .number:
            NumberRow(title: title, value: $variable.number, in: range, step: variable.step > 0 ? variable.step : 1)
        case .toggle:
            Toggle(isOn: $variable.isOn) { title }
        case .text:
            TextField(text: $variable.text) { title }
        case .choice:
            Picker(selection: $variable.text) {
                ForEach(options, id: \.self) { option in
                    Text(verbatim: option).tag(option)
                }
            } label: {
                title
            }
        }
    }

    /// The options to choose from: each once, without the empty lines left while typing them.
    private var options: [String] {
        var seen: Set<String> = []
        return variable.options.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The variable's limits, in order even if they were typed the other way round.
    private var range: ClosedRange<Double> {
        let lower = min(variable.minimum, variable.maximum)
        let upper = max(variable.minimum, variable.maximum)
        return lower < upper ? lower...upper : lower...(lower + 1)
    }
}

/// The inspector of a variable: what it is called, how the scene's code refers to it, its kind
/// and its value.
struct VariableInspector: View {
    @Binding var variable: WallpaperScene.Variable
    let model: SceneEditorModel

    var body: some View {
        Section("Variable") {
            TextField("Title", text: $variable.title)
            KeyField(variable: $variable, model: model)
            Picker("Kind", selection: $variable.kind) {
                ForEach(WallpaperScene.Variable.Kind.allCases, id: \.self) { kind in
                    Text(SceneEditorModel.defaultTitle(for: kind)).tag(kind)
                }
            }
        }
        Section("Value") {
            VariableValueRow(variable: $variable, title: Text("Value"))
            switch variable.kind {
            case .number:
                LimitField(title: "Minimum", value: $variable.minimum)
                LimitField(title: "Maximum", value: $variable.maximum)
                LimitField(title: "Step", value: $variable.step)
            case .choice:
                OptionsField(variable: $variable)
            case .color, .toggle, .text:
                EmptyView()
            }
        }
        Section("In Code") {
            CodeReference(title: "CSS", code: "var(--\(variable.key))")
            CodeReference(title: "JavaScript", code: "wallaero.variables.\(variable.key)")
            CodeReference(title: "Text Layer", code: "{\(variable.key)}")
        }
    }
}

/// The name the scene's code knows the variable by. It is taken over when the field is left or
/// Return is pressed, made fit for code and different from the other variables' names.
private struct KeyField: View {
    @Binding var variable: WallpaperScene.Variable
    let model: SceneEditorModel
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent("Name in Code") {
            TextField("", text: $draft)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .focused($isFocused)
        }
            .onAppear { draft = variable.key }
            .onChange(of: variable.id) { _ in draft = variable.key }
            .onChange(of: variable.key) { draft = $0 }
            .onChange(of: isFocused) { focused in
                if !focused { commit() }
            }
            .onSubmit(commit)
    }

    private func commit() {
        let key = model.scene.uniqueKey(draft, for: variable.id)
        if key != variable.key {
            variable.key = key
        }
        draft = key
    }
}

private struct LimitField: View {
    let title: LocalizedStringKey
    @Binding var value: Double

    var body: some View {
        TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
            .multilineTextAlignment(.trailing)
    }
}

/// The options of a choice, one to a line.
private struct OptionsField: View {
    @Binding var variable: WallpaperScene.Variable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Options, One per Line")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: lines)
                .font(.body)
                .frame(height: 72)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var lines: Binding<String> {
        Binding(
            get: { variable.options.joined(separator: "\n") },
            set: { text in
                // Empty lines are kept while typing, so that Return starts a new option.
                variable.options = text.components(separatedBy: "\n")
                let options = variable.options.filter { !$0.isEmpty }
                if !options.contains(variable.text) {
                    variable.text = options.first ?? ""
                }
            }
        )
    }
}

/// How the variable is written in one kind of code, with a button that copies it.
private struct CodeReference: View {
    let title: LocalizedStringKey
    let code: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(verbatim: code)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}
