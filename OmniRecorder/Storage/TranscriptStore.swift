import Foundation

enum TranscriptStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func transcriptURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("json")
    }

    static func load(for audio: URL) -> Transcript? {
        let url = transcriptURL(for: audio)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Transcript.self, from: data)
    }

    static func save(_ transcript: Transcript, for audio: URL) throws {
        let url = transcriptURL(for: audio)
        let data = try encoder.encode(transcript)
        try data.write(to: url, options: [.atomic])
    }

    static func delete(for audio: URL) {
        try? FileManager.default.removeItem(at: transcriptURL(for: audio))
    }
}
