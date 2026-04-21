import Foundation

protocol TranscriptionProvider {
    var name: String { get }
    var supportsDiarization: Bool { get }
    func transcribe(audioURL: URL) async throws -> Transcript
}

enum TranscriptionError: LocalizedError {
    case noProviderConfigured
    case badResponse(Int, String)
    case malformedResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return "No transcription provider configured. Add your Deepgram API key in Settings."
        case .badResponse(let code, let body):
            let snippet = body.prefix(200)
            return "HTTP \(code): \(snippet)"
        case .malformedResponse:
            return "The provider returned an unexpected response format."
        case .network(let reason):
            return "Network: \(reason)"
        }
    }
}

enum TranscriptionOrchestrator {
    static func defaultProvider() -> (any TranscriptionProvider)? {
        if let deepgram = DeepgramProvider() {
            return deepgram
        }
        return nil
    }
}
