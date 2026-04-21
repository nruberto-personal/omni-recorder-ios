import Foundation

struct Transcript: Codable, Hashable {
    let audioFilename: String
    let modelId: String
    let language: String
    let createdAt: Date
    let fullText: String
    let segments: [TranscriptSegment]
    let words: [TranscriptWord]?
    var rawSpeakers: [String]
    var speakerNames: [String: String]

    init(
        audioFilename: String,
        modelId: String,
        language: String,
        createdAt: Date,
        fullText: String,
        segments: [TranscriptSegment],
        words: [TranscriptWord]?,
        rawSpeakers: [String] = [],
        speakerNames: [String: String] = [:]
    ) {
        self.audioFilename = audioFilename
        self.modelId = modelId
        self.language = language
        self.createdAt = createdAt
        self.fullText = fullText
        self.segments = segments
        self.words = words
        self.rawSpeakers = rawSpeakers
        self.speakerNames = speakerNames
    }

    enum CodingKeys: String, CodingKey {
        case audioFilename, modelId, language, createdAt, fullText
        case segments, words, rawSpeakers, speakerNames
    }

    // Custom decode so Phase 2/3 transcripts (without rawSpeakers/speakerNames) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioFilename = try c.decode(String.self, forKey: .audioFilename)
        modelId = try c.decode(String.self, forKey: .modelId)
        language = try c.decode(String.self, forKey: .language)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        fullText = try c.decode(String.self, forKey: .fullText)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        words = try c.decodeIfPresent([TranscriptWord].self, forKey: .words)
        rawSpeakers = try c.decodeIfPresent([String].self, forKey: .rawSpeakers) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
    }

    func displayName(for rawSpeaker: String) -> String {
        if let name = speakerNames[rawSpeaker], !name.isEmpty {
            return name
        }
        guard let index = rawSpeakers.firstIndex(of: rawSpeaker) else {
            return rawSpeaker
        }
        let scalar = UnicodeScalar(65 + index) ?? UnicodeScalar(63)!
        return "Speaker \(Character(scalar))"
    }
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?

    var id: String { "\(start)-\(end)-\(text.hashValue)" }

    init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }

    enum CodingKeys: String, CodingKey {
        case start, end, text, speaker
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
    }
}

struct TranscriptWord: Codable, Hashable {
    let start: Double
    let end: Double
    let text: String
    let probability: Double
}
