import AVFoundation
import Combine
import Foundation

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    func refresh() async {
        let resourceKeys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            recordings = []
            return
        }

        let audioFiles = urls.filter { $0.pathExtension.lowercased() == "m4a" }

        var loaded: [Recording] = []
        for url in audioFiles {
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let createdAt = values?.creationDate ?? Date()
            let fileSize = Int64(values?.fileSize ?? 0)
            let duration = await probeDuration(url: url)
            loaded.append(Recording(
                id: UUID(),
                url: url,
                createdAt: createdAt,
                duration: duration,
                fileSize: fileSize
            ))
        }

        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        TranscriptStore.delete(for: recording.url)
        Task { await refresh() }
    }

    private func probeDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : 0
        } catch {
            return 0
        }
    }
}
