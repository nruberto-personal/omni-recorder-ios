import Foundation
import WhisperKit

enum WhisperRunnerError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model isn't loaded yet."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}

@MainActor
final class WhisperKitRunner: ObservableObject {
    enum State: Equatable {
        case idle
        case loadingModel
        case ready
        case transcribing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    let modelId: String = "openai_whisper-small.en"
    private var whisperKit: WhisperKit?

    func prepare() async {
        if case .ready = state, whisperKit != nil { return }
        state = .loadingModel
        do {
            let kit = try await WhisperKit(
                model: modelId,
                verbose: false,
                logLevel: .error
            )
            self.whisperKit = kit
            state = .ready
        } catch {
            state = .failed("Failed to load model: \(error.localizedDescription)")
        }
    }

    private static func stripSpecialTokens(_ text: String) -> String {
        // Strip leftover Whisper tokens like <|startoftranscript|>, <|0.00|>, <|endoftext|>
        // even though skipSpecialTokens is on — timestamp tokens occasionally slip through.
        let pattern = #"<\|[^|]*\|>"#
        let cleaned = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(audioURL: URL) async throws -> Transcript {
        if whisperKit == nil {
            await prepare()
        }
        guard let whisperKit else {
            throw WhisperRunnerError.modelNotLoaded
        }

        state = .transcribing

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            skipSpecialTokens: true,
            wordTimestamps: true
        )

        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options
            )
        } catch {
            state = .failed(error.localizedDescription)
            throw WhisperRunnerError.transcriptionFailed(error.localizedDescription)
        }

        let allSegments = results.flatMap { $0.segments }

        let segments: [TranscriptSegment] = allSegments.map { seg in
            TranscriptSegment(
                start: Double(seg.start),
                end: Double(seg.end),
                text: Self.stripSpecialTokens(seg.text)
            )
        }

        let words: [TranscriptWord] = allSegments
            .compactMap { $0.words }
            .flatMap { $0 }
            .map { w in
                TranscriptWord(
                    start: Double(w.start),
                    end: Double(w.end),
                    text: w.word,
                    probability: Double(w.probability)
                )
            }

        let fullText = Self.stripSpecialTokens(
            results.map { $0.text }.joined(separator: " ")
        )

        let language = results.first?.language ?? "en"

        state = .ready

        return Transcript(
            audioFilename: audioURL.lastPathComponent,
            modelId: modelId,
            language: language,
            createdAt: Date(),
            fullText: fullText,
            segments: segments,
            words: words.isEmpty ? nil : words
        )
    }
}
