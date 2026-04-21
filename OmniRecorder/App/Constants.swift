import Foundation

enum AppConstants {
    // Keychain key names for provider API keys
    static let deepgramApiKeyName = "deepgram_api_key"
    static let assemblyaiApiKeyName = "assemblyai_api_key"
    static let groqApiKeyName = "groq_api_key"

    // Legacy — HF Pyannote Space (retained as a reference; the iOS app no longer calls it in Phase 5)
    static let diarizationServiceURL = URL(string: "https://nruberto-omni-recorder-diarization.hf.space")!
}
