import Foundation

enum SpeakerInferenceError: LocalizedError {
    case noKey
    case insufficientData
    case badResponse(Int, String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No Groq API key configured."
        case .insufficientData:
            return "Not enough word-level data to infer speakers."
        case .badResponse(let code, _):
            return "Groq returned HTTP \(code)."
        case .malformedResponse(let reason):
            return "Groq response malformed: \(reason)"
        }
    }
}

struct InferredSpeakerTurns: Decodable {
    let reasoning: String?
    let turns: [InferredTurn]
}

struct InferredTurn: Decodable {
    let speaker: String
    let startWord: Int
    let endWord: Int

    enum CodingKeys: String, CodingKey {
        case speaker
        case startWord = "start_word"
        case endWord = "end_word"
    }
}

enum SpeakerInference {
    private static let model = "llama-3.3-70b-versatile"

    static func inferIfNeeded(from transcript: Transcript) async -> Transcript {
        // Only run when Deepgram gave us 0 or 1 speaker — trust multi-speaker acoustic results
        guard transcript.rawSpeakers.count <= 1 else {
            return transcript
        }
        guard let apiKey = KeychainStore.load(key: AppConstants.groqApiKeyName) else {
            return transcript
        }
        guard let words = transcript.words, !words.isEmpty else {
            return transcript
        }

        do {
            let result = try await callGroq(apiKey: apiKey, words: words)
            if let reasoning = result.reasoning {
                print("[Groq] reasoning: \(reasoning)")
            }
            print("[Groq] inferred \(result.turns.count) turns, \(Set(result.turns.map { $0.speaker }).count) speakers: \(Set(result.turns.map { $0.speaker }))")
            return apply(result, to: transcript, words: words)
        } catch {
            print("[Groq] inference failed: \(error.localizedDescription) — keeping Deepgram output")
            return transcript
        }
    }

    // MARK: - Groq API call

    private static let systemInstructions = """
    You assign each word of a transcript to a speaker using ONLY conversational context. Acoustic diarization failed, so reason purely from text.

    CRITICAL INFERENCE RULES — apply these in order:

    1. Backward AND forward propagation. Once you determine a speaker is "Nathan" based on any single word range, apply that name to ALL other turns by the same speaker — earlier AND later. Do NOT leave earlier turns generic if you later figured out the name.

    2. "Thanks X" / "Thank you X" means the speaker is ADDRESSING X. So X is NOT the current speaker; X is almost always the OTHER party in a two-person conversation.

    3. "Thank you for having me" / "Happy to be here" / "Great to be here" signals the GUEST. Whoever introduced them earlier is the HOST.

    4. Introduction patterns like "We're here today with X" or "It's X" — the speaker is the HOST introducing X. The HOST's name must be inferred from other cues (e.g. later someone says "Thanks, HOSTNAME").

    5. A sequence like "Thank you X, thank you for having me. Great to be here" is ONE continuous turn from the GUEST. Do NOT split it into multiple turns just because there are multiple sentences.

    6. Prefer FEWER turns. Only introduce a turn boundary when there's a clear conversational pivot (e.g. a direct-address, a question-answer pair, a tonal shift). Over-fragmentation is worse than under-fragmentation.

    7. Every human name mentioned almost certainly belongs to someone in the room. Extract aggressively — do not leave someone as "Speaker 1" if there's any textual evidence for their real name.

    8. **CRITICAL**: if your reasoning identifies real names for any speakers, you MUST use those exact names as the `speaker` value in `turns`. NEVER output "Speaker A", "Speaker B", "Speaker 1", or "Speaker 2" for a speaker whose real name you figured out in reasoning. Before finalizing your output, re-check: does every name mentioned in `reasoning` appear at least once as a speaker value in `turns`?

    EXAMPLE (study this pattern carefully):

    Indexed words:
    0:Hi 1:everyone 2:welcome 3:to 4:the 5:show 6:today 7:I'm 8:here 9:with 10:Alice 11:Hey 12:Bob 13:great 14:to 15:be 16:here

    Correct output:
    {
      "reasoning": "Speaker says 'I'm here with Alice' — introducing Alice. Alice responds 'Hey Bob', revealing the introducer is Bob.",
      "turns": [
        {"speaker": "Bob", "start_word": 0, "end_word": 10},
        {"speaker": "Alice", "start_word": 11, "end_word": 16}
      ]
    }

    Note: Bob's name only appears in Alice's speech (as the addressee), yet we correctly labeled the first speaker as Bob — because whoever Alice is addressing IS the introducer. Apply the same backward inference in YOUR output.

    Output format — return ONLY a JSON object:

    {
      "reasoning": "2-4 sentences. Identify each speaker and cite the exact phrase(s) that revealed their name/role.",
      "turns": [
        {"speaker": "Name", "start_word": 0, "end_word": 12}
      ]
    }

    Coverage rules: every word index 0..N-1 must be covered by exactly one turn. Turns must be contiguous and in chronological order.
    """

    private static func callGroq(apiKey: String, words: [TranscriptWord]) async throws -> InferredSpeakerTurns {
        let wordList = words.enumerated()
            .map { index, word in
                let cleaned = word.text.trimmingCharacters(in: .whitespaces)
                return "\(index):\(cleaned)"
            }
            .joined(separator: " ")

        let userMessage = "Indexed words:\n\(wordList)"

        let body = GroqRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemInstructions),
                .init(role: "user", content: userMessage)
            ],
            temperature: 0,
            responseFormat: .init(type: "json_object")
        )

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw SpeakerInferenceError.badResponse(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                bodyString
            )
        }

        let chatResponse: GroqResponse
        do {
            chatResponse = try JSONDecoder().decode(GroqResponse.self, from: data)
        } catch {
            throw SpeakerInferenceError.malformedResponse("envelope: \(error)")
        }

        guard let content = chatResponse.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw SpeakerInferenceError.malformedResponse("empty choices")
        }

        do {
            return try JSONDecoder().decode(InferredSpeakerTurns.self, from: jsonData)
        } catch {
            throw SpeakerInferenceError.malformedResponse("inner JSON: \(error)")
        }
    }

    // MARK: - Apply inference to transcript

    private static func apply(
        _ inference: InferredSpeakerTurns,
        to transcript: Transcript,
        words: [TranscriptWord]
    ) -> Transcript {
        guard !inference.turns.isEmpty else { return transcript }

        var nameToRawID: [String: String] = [:]
        var rawSpeakers: [String] = []
        var speakerNames: [String: String] = [:]
        var segments: [TranscriptSegment] = []

        for turn in inference.turns {
            let startIdx = max(0, turn.startWord)
            let endIdx = min(words.count - 1, turn.endWord)
            guard startIdx <= endIdx else { continue }

            let turnWords = Array(words[startIdx...endIdx])
            let text = turnWords
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            let rawID: String
            if let existing = nameToRawID[turn.speaker] {
                rawID = existing
            } else {
                rawID = String(format: "SPEAKER_%02d", nameToRawID.count)
                nameToRawID[turn.speaker] = rawID
                rawSpeakers.append(rawID)
                if !isGenericLabel(turn.speaker) {
                    speakerNames[rawID] = turn.speaker
                }
            }

            segments.append(TranscriptSegment(
                start: turnWords.first?.start ?? 0,
                end: turnWords.last?.end ?? 0,
                text: text,
                speaker: rawID
            ))
        }

        guard !segments.isEmpty else { return transcript }

        return Transcript(
            audioFilename: transcript.audioFilename,
            modelId: transcript.modelId + "+groq",
            language: transcript.language,
            createdAt: transcript.createdAt,
            fullText: transcript.fullText,
            segments: segments,
            words: transcript.words,
            rawSpeakers: rawSpeakers,
            speakerNames: speakerNames
        )
    }

    static func isGenericLabel(_ name: String) -> Bool {
        // Catches "Speaker 1", "Speaker A", "Speaker b", "SpeakerA", etc.
        name.range(of: #"^Speaker[\s_-]*[\dA-Za-z]$"#, options: .regularExpression) != nil
    }
}

// MARK: - Groq wire types

private struct GroqRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let responseFormat: ResponseFormat

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case responseFormat = "response_format"
    }
}

private struct GroqResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}
