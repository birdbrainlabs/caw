import SwiftUI

/// Settings › Troubleshooting › Read-back results: what the read-back test has
/// measured so far, one row per app. See `ReadbackProbe`.
struct ReadbackResultsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ReadbackAppSummary] = []
    @State private var dictations = 0
    @State private var secure = 0
    @State private var loaded = false
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read-back results")
                .font(.headline)
            Text("For each app: could \(AppEdition.displayName) read the text box back after pasting, did it see your final text before you sent it, and did you change the words.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if rows.isEmpty {
                Text(loaded ? "No results yet. With the read-back test on, dictate into a few apps." : "Loading…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Table(rows) {
                    TableColumn("App", value: \.appName)
                    TableColumn("Dictations") { row in Text("\(row.dictations)") }
                    TableColumn("Readable") { row in Text(row.readablePercent) }
                    TableColumn("Final captured") { row in Text(row.capturedPercent) }
                    TableColumn("Edited (of captured)") { row in Text(row.editedPercent) }
                }
                .frame(minHeight: 180)

                Text("\(dictations) dictations" + (secure > 0 ? ", \(secure) into password fields (not read)" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Show Log File") { ReadbackProbe.shared.revealLogFile() }
                Button("Clear Results") { confirmingClear = true }
                    .disabled(rows.isEmpty)
                Spacer()
                Button("Refresh") { load() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 380)
        .onAppear(perform: load)
        .confirmationDialog("Clear all read-back results?", isPresented: $confirmingClear) {
            Button("Clear Results", role: .destructive) {
                ReadbackProbe.shared.clearResults { load() }
            }
        } message: {
            Text("This deletes readback-probe.jsonl. It cannot be undone.")
        }
    }

    private func load() {
        ReadbackProbe.shared.loadRecords { records in
            rows = ReadbackResults.summarize(records)
            dictations = records.count
            secure = records.filter(\.secure).count
            loaded = true
        }
    }
}
