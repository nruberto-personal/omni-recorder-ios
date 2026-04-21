import Foundation

struct DeepgramProvider: TranscriptionProvider {
    let name = "Deepgram"
    let supportsDiarization = true

    private let apiKey: String
    private let model: String

    init?(model: String = "nova-2-conversationalai") {
        guard let key = KeychainStore.load(key: AppConstants.deepgramApiKeyName) else {
            return nil
        }
        self.apiKey = key
        self.model = model
    }

    func transcribe(audioURL: URL) async throws -> Transcript {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "paragraphs", value: "true"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "filler_words", value: "false"),
            URLQueryItem(name: "utterances", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType(for: audioURL), forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: audioURL)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.badResponse(0, "No HTTP response")
        }

        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.badResponse(http.statusCode, body)
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TranscriptionError.malformedResponse
        }

        return try parse(decoded, audioURL: audioURL)
    }

    private func parse(_ response: Response, audioURL: URL) throws -> Transcript {
        guard let alternative = response.results.channels.first?.alternatives.first else {
            throw TranscriptionError.malformedResponse
        }

        let fullText = alternative.transcript
        let language = response.metadata?.detectedLanguage ?? "en"
        let allWords = alternative.words ?? []

        // Word-level grouping is more reliable than paragraph-level: Deepgram's
        // paragraphs are segmented by sentence/pause, and each paragraph carries
        // a single (dominant) speaker — so a paragraph spanning multiple speakers
        // collapses to one. Words carry per-word speaker labels, so grouping
        // consecutive same-speaker words recovers the actual turns.
        let segments: [TranscriptSegment]
        if !allWords.isEmpty {
            segments = groupWordsIntoSegments(allWords)
        } else if let paragraphs = alternative.paragraphs?.paragraphs, !paragraphs.isEmpty {
            segments = paragraphs.map { p in
                TranscriptSegment(
                    start: p.start,
                    end: p.end,
                    text: p.sentences.map { $0.text }.joined(separator: " "),
                    speaker: speakerID(for: p.speaker)
                )
            }
        } else {
            segments = [TranscriptSegment(start: 0, end: 0, text: fullText, speaker: nil)]
        }

        let uniqueSpeakers = Set(allWords.compactMap { $0.speaker })
        print("[Deepgram] \(allWords.count) words, \(uniqueSpeakers.count) unique speakers: \(uniqueSpeakers.sorted())")

        var seen = Set<String>()
        var rawSpeakers: [String] = []
        for seg in segments {
            if let s = seg.speaker, !seen.contains(s) {
                seen.insert(s)
                rawSpeakers.append(s)
            }
        }

        let mappedWords: [TranscriptWord] = allWords.map { w in
            TranscriptWord(
                start: w.start,
                end: w.end,
                text: w.punctuatedWord ?? w.word,
                probability: w.confidence
            )
        }

        return Transcript(
            audioFilename: audioURL.lastPathComponent,
            modelId: "deepgram-\(model)",
            language: language,
            createdAt: Date(),
            fullText: fullText,
            segments: segments,
            words: mappedWords.isEmpty ? nil : mappedWords,
            rawSpeakers: rawSpeakers,
            speakerNames: [:]
        )
    }

    private func groupWordsIntoSegments(_ words: [Word]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var currentSpeaker: String? = nil
        var currentWords: [String] = []
        var currentStart: Double = 0
        var currentEnd: Double = 0

        for w in words {
            let sp = speakerID(for: w.speaker)
            if sp == currentSpeaker {
                currentWords.append(w.punctuatedWord ?? w.word)
                currentEnd = w.end
            } else {
                if !currentWords.isEmpty {
                    result.append(TranscriptSegment(
                        start: currentStart,
                        end: currentEnd,
                        text: currentWords.joined(separator: " "),
                        speaker: currentSpeaker
                    ))
                }
                currentSpeaker = sp
                currentWords = [w.punctuatedWord ?? w.word]
                currentStart = w.start
                currentEnd = w.end
            }
        }
        if !currentWords.isEmpty {
            result.append(TranscriptSegment(
                start: currentStart,
                end: currentEnd,
                text: currentWords.joined(separator: " "),
                speaker: currentSpeaker
            ))
        }
        return result
    }

    private func speakerID(for speaker: Int?) -> String? {
        guard let s = speaker else { return nil }
        return String(format: "SPEAKER_%02d", s)
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Response types

private extension DeepgramProvider {
    struct Response: Codable {
        let metadata: Metadata?
        let results: Results
    }

    struct Metadata: Codable {
        let detectedLanguage: String?
        enum CodingKeys: String, CodingKey {
            case detectedLanguage = "detected_language"
        }
    }

    struct Results: Codable {
        let channels: [Channel]
    }

    struct Channel: Codable {
        let alternatives: [Alternative]
    }

    struct Alternative: Codable {
        let transcript: String
        let confidence: Double?
        let words: [Word]?
        let paragraphs: Paragraphs?
    }

    struct Paragraphs: Codable {
        let transcript: String?
        let paragraphs: [Paragraph]
    }

    struct Paragraph: Codable {
        let sentences: [Sentence]
        let speaker: Int?
        let numWords: Int?
        let start: Double
        let end: Double

        enum CodingKeys: String, CodingKey {
            case sentences, speaker, start, end
            case numWords = "num_words"
        }
    }

    struct Sentence: Codable {
        let text: String
        let start: Double
        let end: Double
    }

    struct Word: Codable {
        let word: String
        let punctuatedWord: String?
        let start: Double
        let end: Double
        let confidence: Double
        let speaker: Int?

        enum CodingKeys: String, CodingKey {
            case word, start, end, confidence, speaker
            case punctuatedWord = "punctuated_word"
        }
    }
}
