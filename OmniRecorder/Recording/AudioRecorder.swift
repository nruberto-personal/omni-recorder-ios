import AVFoundation
import Combine
import Foundation

enum RecorderError: LocalizedError {
    case permissionDenied
    case startFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Enable it in Settings → Omni Recorder → Microphone."
        case .startFailed:
            return "Failed to start recording."
        }
    }
}

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startDate: Date?

    func start() {
        errorMessage = nil
        Task {
            do {
                try await ensureMicPermission()
                try AudioSessionManager.configureForRecording()

                let url = makeNewRecordingURL()
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    AVEncoderBitRateKey: 96_000
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.prepareToRecord()

                guard recorder.record() else {
                    errorMessage = RecorderError.startFailed.errorDescription
                    AudioSessionManager.deactivate()
                    return
                }

                self.recorder = recorder
                self.startDate = Date()
                self.isRecording = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
                AudioSessionManager.deactivate()
            }
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        stopTimer()
        isRecording = false
        elapsedTime = 0
        startDate = nil
        AudioSessionManager.deactivate()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func ensureMicPermission() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RecorderError.permissionDenied
        }
    }

    private func makeNewRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "recording_\(formatter.string(from: Date())).m4a"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(filename)
    }
}
