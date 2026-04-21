import SwiftUI

struct SettingsView: View {
    @State private var deepgramKey: String = ""
    @State private var groqKey: String = ""
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section {
                SecureField("paste Deepgram API key", text: $deepgramKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                keyControls(
                    value: $deepgramKey,
                    keychainName: AppConstants.deepgramApiKeyName,
                    providerName: "Deepgram"
                )
            } header: {
                Text("Deepgram")
            } footer: {
                Text("Primary transcription + diarization provider. Free key at [deepgram.com](https://deepgram.com). Stored in iOS Keychain.")
            }

            Section {
                SecureField("paste Groq API key", text: $groqKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                keyControls(
                    value: $groqKey,
                    keychainName: AppConstants.groqApiKeyName,
                    providerName: "Groq"
                )
            } header: {
                Text("Groq")
            } footer: {
                Text("LLM-based speaker inference fallback. When Deepgram can only detect one speaker, the transcript is sent to Groq's llama-3.3-70b to infer speaker turns and real names from context. Free key at [console.groq.com/keys](https://console.groq.com/keys).")
            }

            if let savedMessage {
                Section {
                    Text(savedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            deepgramKey = KeychainStore.load(key: AppConstants.deepgramApiKeyName) ?? ""
            groqKey = KeychainStore.load(key: AppConstants.groqApiKeyName) ?? ""
        }
    }

    @ViewBuilder
    private func keyControls(value: Binding<String>, keychainName: String, providerName: String) -> some View {
        HStack {
            Button("Save") {
                do {
                    try KeychainStore.save(value.wrappedValue, key: keychainName)
                    savedMessage = value.wrappedValue.isEmpty
                        ? "\(providerName) key cleared."
                        : "\(providerName) key saved."
                } catch {
                    savedMessage = "Failed to save \(providerName) key: \(error.localizedDescription)"
                }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            if !value.wrappedValue.isEmpty {
                Button(role: .destructive) {
                    value.wrappedValue = ""
                    KeychainStore.delete(key: keychainName)
                    savedMessage = "\(providerName) key cleared."
                } label: {
                    Text("Clear")
                }
            }
        }
    }
}
