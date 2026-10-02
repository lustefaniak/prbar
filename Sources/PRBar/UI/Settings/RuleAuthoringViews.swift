import SwiftUI

/// Everything a stage's rules can read, searchable; a click inserts it.
struct FactsPanel: View {
    let stage: RuleCatalog.Stage
    let lists: [String]
    let insert: (String) -> Void
    @State private var search = ""

    private var facts: [RuleCatalog.Fact] {
        RuleCatalog.facts(stage).filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || $0.help.localizedCaseInsensitiveContains(search) }
    }

    private var functions: [RuleCatalog.Function] {
        RuleCatalog.functions.filter { search.isEmpty || $0.signature.localizedCaseInsensitiveContains(search) || $0.help.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search facts and functions", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("Facts") {
                        ForEach(facts) { fact in
                            row(fact.path, fact.type, fact.help) {
                                // A list element's field is read inside exists()/all().
                                insert(fact.path.contains("[]") ? fact.name : fact.path)
                            }
                        }
                    }
                    if !lists.isEmpty {
                        section("Your lists") {
                            ForEach(lists, id: \.self) { name in
                                row("lists.\(name)", "list of strings", "From lists.yaml.") { insert("lists.\(name)") }
                            }
                        }
                    }
                    section("Functions") {
                        ForEach(functions) { function in
                            row(function.signature, "", function.help) {
                                insert(function.template.replacingOccurrences(of: "$0", with: ""))
                            }
                        }
                    }
                    if stage != .configure {
                        section("Severities") {
                            ForEach(RuleCatalog.constants, id: \.self) { name in
                                row(name, "int", "Compare findings by rank.") { insert(name) }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 440, height: 480)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ name: String, _ type: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(name).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(type).font(.caption2).foregroundStyle(.tertiary)
                }
                if !help.isEmpty {
                    Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Rules to start from, by what they do.
struct RuleExamplesSheet: View {
    let workbench: RulesWorkbench
    let prs: [InboxPR]
    let done: () -> Void

    private var examples: [RuleExamples.Example] {
        RuleExamples.all(repository: prs.first?.nameWithOwner, viewer: prs.compactMap(\.viewerLogin).first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start from an example").font(.title3.bold())
            Text("Each one adjusts what Review defaults decide in one way. It opens unsaved, so you can try it on PRs and see what it changes before saving.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(RuleCatalog.Stage.allCases, id: \.self) { stage in
                    Section(Self.title(stage)) {
                        ForEach(examples.filter { $0.stage == stage }) { example in
                            Button {
                                workbench.start(example)
                                done()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(example.title)
                                    Text(example.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 560, height: 520)
    }

    static func title(_ stage: RuleCatalog.Stage) -> String {
        switch stage {
        case .configure: return "Configure: settings per repository"
        case .select: return "Select: review or skip"
        case .decide: return "Decide: what is posted"
        }
    }
}

/// A rule from choices: when (conditions on facts) and what (outputs).
struct RuleBuilderSheet: View {
    let workbench: RulesWorkbench
    let done: () -> Void
    @State private var builder = RuleBuilder(stage: .decide, name: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Build a rule").font(.title3.bold())
            Form {
                Picker("Stage", selection: Binding(get: { builder.stage }, set: { stage in
                    builder.stage = stage
                    builder.conditions = []
                    builder.outputs = [:]
                })) {
                    ForEach(RuleCatalog.Stage.allCases, id: \.self) { Text(RuleExamplesSheet.title($0)).tag($0) }
                }
                TextField("Name", text: $builder.name, prompt: Text("what it is for, like large-gets-a-human"))

                Section {
                    ForEach($builder.conditions) { $condition in
                        ConditionRow(condition: $condition, stage: builder.stage, lists: workbench.listNames) {
                            builder.conditions.removeAll { $0.id == condition.id }
                        }
                    }
                    HStack {
                        Button("Add a condition") {
                            let fact = RuleBuilder.facts(builder.stage).first
                            let op = fact.map { RuleBuilder.operators(for: $0.kind, path: $0.path).first ?? .equals } ?? .equals
                            builder.conditions.append(.init(fact: fact?.path ?? "", op: op))
                        }
                        if builder.conditions.count > 1 {
                            Picker("", selection: $builder.all) {
                                Text("All must hold").tag(true)
                                Text("Any may hold").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text(builder.conditions.isEmpty ? "No condition: it always applies." : builder.condition)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }

                Section("Then") {
                    OutputFields(fields: builder.fields.filter { $0.name != "rule" }, prefix: "", outputs: $builder.outputs)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Opens unsaved, to try before saving.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Create") {
                    let lists = builder.conditions.filter { $0.op == .inList || $0.op == .notInList }
                        .map { RuleBuilder.identifier($0.value) }
                    workbench.addLists(Dictionary(lists.map { ($0, []) }, uniquingKeysWith: { a, _ in a }))
                    let name = RuleExamples.slug(builder.name.isEmpty ? "my-rule" : builder.name)
                    workbench.newFile(workbench.freePath("\(builder.stage.rawValue)/50-\(name).yaml"), text: builder.yaml)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding()
        .frame(width: 640, height: 640)
        .onAppear {
            guard ScreenshotMode.isActive, ScreenshotMode.rulesAction == "builder" else { return }
            builder.name = "large from outside the core"
            builder.conditions = [
                .init(fact: "below.action", op: .equals, value: "approve"),
                .init(fact: "pr.author", op: .notInList, value: "core"),
                .init(fact: "pr.additions", op: .greater, value: "300"),
            ]
            builder.outputs = ["action": "share", "min_severity": "warning"]
        }
    }

    /// select and decide need an action; configure needs something set.
    private var canCreate: Bool {
        switch builder.stage {
        case .configure: return !builder.outputs.values.allSatisfy(\.isEmpty)
        case .select, .decide: return !(builder.outputs["action"] ?? "").isEmpty
        }
    }

    private struct ConditionRow: View {
        @Binding var condition: RuleBuilder.Condition
        let stage: RuleCatalog.Stage
        let lists: [String]
        let remove: () -> Void

        private var fact: RuleCatalog.Fact? { RuleCatalog.facts(stage).first { $0.path == condition.fact } }
        private var operators: [RuleBuilder.Operator] {
            fact.map { RuleBuilder.operators(for: $0.kind, path: $0.path) } ?? []
        }

        var body: some View {
            HStack {
                Picker("", selection: Binding(get: { condition.fact }, set: { path in
                    condition.fact = path
                    let kind = RuleCatalog.facts(stage).first { $0.path == path }?.kind ?? .other
                    let ops = RuleBuilder.operators(for: kind, path: path)
                    if !ops.contains(condition.op) { condition.op = ops.first ?? .equals }
                })) {
                    ForEach(RuleBuilder.facts(stage)) { fact in
                        Text(fact.path).tag(fact.path)
                    }
                }
                .frame(width: 200)
                .help(fact?.help ?? "")
                Picker("", selection: $condition.op) {
                    ForEach(operators) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 170)
                if condition.op == .inList || condition.op == .notInList {
                    TextField("list", text: $condition.value, prompt: Text(lists.first ?? "trusted"))
                        .textFieldStyle(.roundedBorder)
                } else if condition.op.takesValue {
                    TextField("value", text: $condition.value, prompt: Text(placeholder))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Spacer()
                }
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            .labelsHidden()
        }

        private var placeholder: String {
            switch condition.op {
            case .longer, .shorter: return "3 days"
            case .globs, .anyFile, .everyFile: return "docs/**"
            case .greater, .less: return "400"
            default: return fact?.help.split(separator: ".").first.map(String.init) ?? ""
            }
        }
    }

    private struct OutputFields: View {
        let fields: [RuleOutputs.Field]
        let prefix: String
        @Binding var outputs: [String: String]

        /// Environment maps are written in the editor; the rest here.
        private var shown: [RuleOutputs.Field] {
            fields.filter { if case .stringMap = $0.kind { return false }; return true }
        }

        var body: some View {
            ForEach(shown, id: \.name) { field in
                let key = prefix + field.name
                switch field.kind {
                case .object(let inner):
                    DisclosureGroup(field.name) {
                        OutputFields(fields: inner, prefix: key + ".", outputs: $outputs)
                    }
                    .help(field.help)
                case .oneOf(let values):
                    choice(field, key: key, values: values)
                case .bool:
                    choice(field, key: key, values: ["true", "false"])
                case .severity:
                    choice(field, key: key, values: AnnotationSeverity.allCases.map(\.rawValue))
                default:
                    TextField(field.name, text: binding(key), prompt: Text(prompt(field)))
                        .help(field.help)
                }
            }
        }

        private func choice(_ field: RuleOutputs.Field, key: String, values: [String]) -> some View {
            Picker(field.name, selection: binding(key)) {
                Text(field.required ? "choose" : "not set").tag("")
                ForEach(values, id: \.self) { value in
                    Text(value).tag(value)
                }
            }
            .help(field.help + (field.values.isEmpty ? "" : " " + values.map { "\($0): \(field.values[$0] ?? "")" }.joined(separator: " ")))
        }

        private func prompt(_ field: RuleOutputs.Field) -> String {
            switch field.kind {
            case .strings: return "comma separated"
            case .stringMap: return ""
            default: return "not set"
            }
        }

        private func binding(_ key: String) -> Binding<String> {
            Binding(get: { outputs[key] ?? "" }, set: { outputs[key] = $0 })
        }
    }
}
