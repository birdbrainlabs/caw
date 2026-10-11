import SwiftUI

/// Settings › Words & Learning: the user's word fixes as an editable list,
/// suggested fixes waiting for a yes or no, and a box to try a sentence.
///
/// Edits save to word-fixes.json (atomically, a moment after typing stops, and
/// when the window closes) and apply to the next dictation — the same file and
/// the same meaning as editing it by hand.
@MainActor
final class WordFixEditorModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var fix: WordFix
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var suggestions: [WordFixSuggestion] = []
    @Published private(set) var problem: String?
    @Published private(set) var saveError: String?
    @Published private(set) var lastDeleted: (row: Row, index: Int)?
    @Published var testInput = "" { didSet { refreshTest() } }
    @Published private(set) var testOutput = ""

    private let store: WordFixStore
    private let suggestionStore: WordFixSuggestionStore
    private var hasUnsavedChanges = false
    private var saveTask: Task<Void, Never>?
    private var compiled = CompiledWordFixes.empty

    init(store: WordFixStore = .shared, suggestionStore: WordFixSuggestionStore = .shared) {
        self.store = store
        self.suggestionStore = suggestionStore
    }

    var fileURL: URL { store.fileURL }

    /// Re-reads the file, unless there are edits here not yet saved.
    func reload() {
        guard !hasUnsavedChanges else { return }
        _ = store.current            // refreshes `problem` if the file changed
        rows = (store.loadFile()?.fixes ?? []).map { Row(fix: $0) }
        suggestions = suggestionStore.pending
        problem = store.problem
        recompile()
    }

    // MARK: Editing

    func binding<Value>(_ id: Row.ID, _ keyPath: WritableKeyPath<WordFix, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { [weak self] in self?.rows.first { $0.id == id }?.fix[keyPath: keyPath] ?? fallback },
            set: { [weak self] newValue in
                guard let self, let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
                self.rows[index].fix[keyPath: keyPath] = newValue
                self.changed()
            }
        )
    }

    func add(heard: String, shouldBe: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldBe = shouldBe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !shouldBe.isEmpty else { return }
        rows.append(Row(fix: WordFix(from: heard, to: shouldBe, capitalization: .matchHeard)))
        changed()
    }

    func delete(_ id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        lastDeleted = (rows.remove(at: index), index)
        changed(keepUndo: true)
    }

    func undoDelete() {
        guard let deleted = lastDeleted else { return }
        rows.insert(deleted.row, at: min(deleted.index, rows.count))
        lastDeleted = nil
        changed()
    }

    /// Fixes apply top to bottom, so order can matter.
    func move(_ id: Row.ID, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
        changed()
    }

    func isFirst(_ id: Row.ID) -> Bool { rows.first?.id == id }
    func isLast(_ id: Row.ID) -> Bool { rows.last?.id == id }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges else { return }
        do {
            try store.save(rows.map(\.fix))
            hasUnsavedChanges = false
            saveError = nil
            problem = store.problem
        } catch {
            saveError = "Could not save word-fixes.json: \(error.localizedDescription)"
        }
    }

    private func changed(keepUndo: Bool = false) {
        if !keepUndo { lastDeleted = nil }
        hasUnsavedChanges = true
        recompile()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: Suggestions

    func approve(_ suggestion: WordFixSuggestion) {
        saveNow()                   // the approval appends to what is on disk
        do {
            try suggestionStore.approve(id: suggestion.id)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
        reload()
    }

    func reject(_ suggestion: WordFixSuggestion) {
        do {
            try suggestionStore.reject(id: suggestion.id)
        } catch {
            saveError = error.localizedDescription
        }
        suggestions = suggestionStore.pending
    }

    // MARK: Test a sentence

    private func recompile() {
        compiled = CompiledWordFixes(rows.map(\.fix))
        refreshTest()
    }

    /// The same cleanup every dictation gets, with the list as it is on screen
    /// (saved or not). Punctuate Automatically is a separate step, not run here.
    private func refreshTest() {
        guard !testInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            testOutput = ""
            return
        }
        var cleaner = TranscriptDisfluencyCleaner()
        cleaner.breaksRunOnSentences = !LiveTranscriptionController.usesModernEngine
        cleaner.wordFixes = compiled
        testOutput = cleaner.clean(testInput)
    }
}

/// The Words & Learning sections of Settings. Several sections, so the Form
/// lays them out like its others.
struct WordFixesSections: View {
    @ObservedObject var model: WordFixEditorModel
    /// Suggestions are learned from the read-back test, so say when it is off.
    @AppStorage(ReadbackProbe.enabledKey) private var readbackEnabled = !AppEdition.isBeta
    @State private var newHeard = ""
    @State private var newShouldBe = ""

    var body: some View {
        Section {
            Text("Word fixes: when the left is heard, the right is written.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.rows) { row in
                WordFixRowView(model: model, id: row.id, fix: row.fix)
            }

            if let deleted = model.lastDeleted {
                HStack {
                    Text("Deleted “\(deleted.row.fix.from) → \(deleted.row.fix.to)”")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Undo") { model.undoDelete() }
                }
            }

            HStack(spacing: 6) {
                TextField("Heard", text: $newHeard, prompt: Text("heard"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Should be", text: $newShouldBe, prompt: Text("should be"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button("Add") {
                    model.add(heard: newHeard, shouldBe: newShouldBe)
                    newHeard = ""
                    newShouldBe = ""
                }
                .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty
                          || newShouldBe.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = model.saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let problem = model.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Applied top to bottom. “Heard” ignores capitals; put | between words that sound alike.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open File") {
                    model.saveNow()
                    NSWorkspace.shared.open(model.fileURL)
                }
                .controlSize(.small)
            }
        } header: {
            Text("Words & Learning")
        }

        Section("Suggested Fixes") {
            // The same switch as the Read-back test under Troubleshooting:
            // learning is what the read-back is for. First-run setup points
            // Beta testers here to turn it off.
            Toggle("Learn From My Fixes", isOn: $readbackEnabled)
            if model.suggestions.isEmpty {
                Text(readbackEnabled
                     ? "Suggestions will appear here once \(AppEdition.brandName) has learned from your edits."
                     : "Learning is off, so no new suggestions will appear.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.suggestions) { suggestion in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(suggestion.heard) → \(suggestion.shouldBe)"
                                 + (suggestion.count.map { " · \($0) time\($0 == 1 ? "" : "s")" } ?? ""))
                            if suggestion.commonWord == true {
                                Text("careful: common word")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if let example = suggestion.example {
                                Text("“\(example)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Approve") { model.approve(suggestion) }
                        Button("Reject") { model.reject(suggestion) }
                    }
                }
                Text("Learned from words you changed after dictating. Nothing is applied until you approve. Approve adds it to your word fixes; Reject hides it for good.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Test a Sentence") {
            TextField("Test a sentence", text: $model.testInput, prompt: Text("Type or dictate a sentence"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .lineLimit(2...5)
            if !model.testOutput.isEmpty {
                Text(model.testOutput)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Shows what the cleanup and your word fixes make of it, including edits not saved yet. Punctuate Automatically is not included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WordFixRowView: View {
    @ObservedObject var model: WordFixEditorModel
    let id: WordFixEditorModel.Row.ID
    let fix: WordFix

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField("Heard", text: model.binding(id, \.from, fallback: ""), prompt: Text("heard"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Should be", text: model.binding(id, \.to, fallback: ""), prompt: Text("should be"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Menu {
                    Picker("Capitals", selection: model.binding(id, \.capitalization, fallback: .matchHeard)) {
                        Text("Always a capital (a name)").tag(WordFix.Capitalization.always)
                        Text("Capital only if heard with one").tag(WordFix.Capitalization.matchHeard)
                        Text("Exactly as typed, even starting a sentence").tag(WordFix.Capitalization.exact)
                    }
                    .pickerStyle(.inline)
                    Toggle("Whole words only", isOn: model.binding(id, \.wholeWord, fallback: true))
                    Divider()
                    Button("Move Up") { model.move(id, by: -1) }
                        .disabled(model.isFirst(id))
                    Button("Move Down") { model.move(id, by: 1) }
                        .disabled(model.isLast(id))
                    Divider()
                    Button("Delete", role: .destructive) { model.delete(id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Options, order and delete")
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var parts: [String]
        switch fix.capitalization {
        case .always: parts = ["Always a capital"]
        case .matchHeard: parts = ["Capital only if heard with one"]
        case .exact: parts = ["Exactly as typed"]
        }
        if !fix.wholeWord { parts.append("also inside longer words") }
        if fix.endings != WordFix.defaultEndings { parts.append("custom endings (in the file)") }
        return parts.joined(separator: " · ")
    }
}
