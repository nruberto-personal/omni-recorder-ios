import SwiftUI

@main
struct OmniRecorderApp: App {
    init() {
        seedDevSecretsIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }

    // Dev convenience: if .env had a DEEPGRAM_KEY, embed-dev-secrets.py baked it into
    // DevSecrets.deepgramKey at build time. Seed the Keychain from there on first run
    // so you don't have to paste it into Settings on every device.
    // User-entered keys (via Settings) always win once saved.
    private func seedDevSecretsIfNeeded() {
        seed(keyName: AppConstants.deepgramApiKeyName, value: DevSecrets.deepgramKey)
        seed(keyName: AppConstants.groqApiKeyName, value: DevSecrets.groqKey)
    }

    private func seed(keyName: String, value: String?) {
        guard KeychainStore.load(key: keyName) == nil,
              let value,
              !value.isEmpty else {
            return
        }
        try? KeychainStore.save(value, key: keyName)
    }
}
