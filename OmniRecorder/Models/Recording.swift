import Foundation

struct Recording: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let createdAt: Date
    let duration: TimeInterval
    let fileSize: Int64

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}
