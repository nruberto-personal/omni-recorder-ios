import SwiftUI

struct RecorderView: View {
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var store: RecordingStore

    var body: some View {
        VStack(spacing: 20) {
            Text(formatDuration(recorder.elapsedTime))
                .font(.system(size: 52, weight: .light, design: .monospaced))
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
                .contentTransition(.numericText())
                .animation(.default, value: recorder.elapsedTime)

            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 96, height: 96)
                        .shadow(radius: 4)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")

            if let message = recorder.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }

    private func toggle() {
        if recorder.isRecording {
            recorder.stop()
            Task { await store.refresh() }
        } else {
            recorder.start()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
