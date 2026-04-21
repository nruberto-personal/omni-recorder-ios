import AVFoundation
import SwiftUI
import UIKit

struct RecordingDetailView: View {
    let recording: Recording

    @State private var transcript: Transcript?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var isFlowActive = false
    @State private var flowError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                playbackControls
                Divider()
                transcriptSection
            }
            .padding()
        }
        .navigationTitle(recording.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            transcript = TranscriptStore.load(for: recording.url)
        }
        .onDisappear {
            audioPlayer?.stop()
            audioPlayer = nil
            isPlaying = false
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.displayName).font(.headline)
            HStack(spacing: 12) {
                Label(formatDuration(recording.duration), systemImage: "clock")
                Label(formatSize(recording.fileSize), systemImage: "doc")
                Text(recording.createdAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var playbackControls: some View {
        Button(action: togglePlayback) {
            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if isFlowActive {
            flowProgress
        } else if let error = flowError {
            flowFailed(error)
        } else if let transcript {
            rendered(transcript)
        } else {
            Button(action: transcribe) {
                Label("Transcribe", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var flowProgress: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Uploading + transcribing…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Keep the app foreground for up to ~30 seconds after uploading. Screen stays on.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func flowFailed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Retry") { transcribe() }
                    .buttonStyle(.bordered)
                NavigationLink("Open Settings", value: RootView.Route.settings)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func rendered(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Transcribed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                Spacer()
                Text(transcript.modelId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(turns(from: transcript)) { turn in
                    TurnView(
                        turn: turn,
                        transcript: transcript,
                        onRename: renameSpeaker
                    )
                }
            }
            .textSelection(.enabled)

            Button(action: transcribe) {
                Label("Re-transcribe", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 8)
        }
    }

    // MARK: - Turn grouping

    struct Turn: Identifiable, Hashable {
        let start: Double
        let rawSpeaker: String?
        let text: String
        var id: String { "\(start)-\(rawSpeaker ?? "nil")" }
    }

    private func turns(from transcript: Transcript) -> [Turn] {
        var result: [Turn] = []
        for seg in transcript.segments {
            if let last = result.last, last.rawSpeaker == seg.speaker {
                result[result.count - 1] = Turn(
                    start: last.start,
                    rawSpeaker: last.rawSpeaker,
                    text: last.text + " " + seg.text
                )
            } else {
                result.append(Turn(
                    start: seg.start,
                    rawSpeaker: seg.speaker,
                    text: seg.text
                ))
            }
        }
        return result
    }

    // MARK: - Actions

    private func transcribe() {
        isFlowActive = true
        flowError = nil

        guard let provider = TranscriptionOrchestrator.defaultProvider() else {
            isFlowActive = false
            flowError = TranscriptionError.noProviderConfigured.errorDescription
            return
        }

        let existingNames = transcript?.speakerNames ?? [:]
        let audioURL = recording.url

        UIApplication.shared.isIdleTimerDisabled = true
        let bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "transcribe") { }

        Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }

            do {
                var result = try await provider.transcribe(audioURL: audioURL)
                // If acoustic diarization found <2 speakers, ask Groq to infer from text.
                // Returns the original transcript unchanged if no Groq key or if inference fails.
                result = await SpeakerInference.inferIfNeeded(from: result)
                // Carry over existing speaker names ONLY when the fresh run didn't produce one
                // and the saved name is a real user rename (not a stale generic "Speaker A" from
                // an earlier buggy run). Lets fresh Groq inferences always win, while preserving
                // manual renames when Groq couldn't improve on them.
                for (rawId, name) in existingNames
                where result.rawSpeakers.contains(rawId)
                    && result.speakerNames[rawId] == nil
                    && !SpeakerInference.isGenericLabel(name) {
                    result.speakerNames[rawId] = name
                }
                try? TranscriptStore.save(result, for: audioURL)
                transcript = result
            } catch {
                flowError = error.localizedDescription
            }
            isFlowActive = false
        }
    }

    private func renameSpeaker(raw: String, to newName: String) {
        guard var t = transcript else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            t.speakerNames.removeValue(forKey: raw)
        } else {
            t.speakerNames[raw] = trimmed
        }
        transcript = t
        try? TranscriptStore.save(t, for: recording.url)
    }

    private func togglePlayback() {
        if audioPlayer == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try? AVAudioPlayer(contentsOf: recording.url)
            audioPlayer?.prepareToPlay()
        }
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct TurnView: View {
    let turn: RecordingDetailView.Turn
    let transcript: Transcript
    let onRename: (String, String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timecode(turn.start))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                speakerLabel
            }
            Text(turn.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 56)
        }
    }

    @ViewBuilder
    private var speakerLabel: some View {
        if let raw = turn.rawSpeaker {
            if isEditing {
                TextField("Speaker name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .focused($isFocused)
                    .onSubmit { commit(raw: raw) }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit(raw: raw) }
                    }
                    .frame(maxWidth: 220)
            } else {
                Button {
                    draft = transcript.displayName(for: raw)
                    isEditing = true
                    isFocused = true
                } label: {
                    Text(transcript.displayName(for: raw))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("Unknown speaker")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func commit(raw: String) {
        guard isEditing else { return }
        onRename(raw, draft)
        isEditing = false
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
