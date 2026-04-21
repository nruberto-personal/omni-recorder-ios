import SwiftUI

struct RecordingsListView: View {
    @ObservedObject var store: RecordingStore

    var body: some View {
        Group {
            if store.recordings.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text("Tap the mic button to record your first meeting.")
                )
            } else {
                List {
                    ForEach(store.recordings) { recording in
                        NavigationLink(value: recording) {
                            RecordingRow(recording: recording)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.plain)
            }
        }
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            store.delete(store.recordings[index])
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.displayName)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 12) {
                Label(formatDuration(recording.duration), systemImage: "clock")
                Label(formatSize(recording.fileSize), systemImage: "doc")
                Text(recording.createdAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
