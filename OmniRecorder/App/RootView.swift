import SwiftUI

struct RootView: View {
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var store = RecordingStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RecorderView(recorder: recorder, store: store)
                    .padding(.vertical, 24)
                Divider()
                RecordingsListView(store: store)
            }
            .navigationTitle("Omni Recorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: Recording.self) { recording in
                RecordingDetailView(recording: recording)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .settings: SettingsView()
                }
            }
        }
    }

    enum Route: Hashable {
        case settings
    }
}
