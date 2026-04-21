import Foundation

struct RawSpeakerSegment: Codable, Hashable {
    let start: Double
    let end: Double
    let speaker: String
}

enum DiarizationError: LocalizedError {
    case badResponse(Int, String)
    case network(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code, _):
            return "Diarization service returned HTTP \(code)."
        case .network(let reason):
            return "Network: \(reason)"
        case .decode(let reason):
            return "Decode: \(reason)"
        }
    }
}

private struct DiarizationResponse: Codable {
    let segments: [RawSpeakerSegment]
    let numSpeakers: Int
    let duration: Double

    enum CodingKeys: String, CodingKey {
        case segments
        case numSpeakers = "num_speakers"
        case duration
    }
}

enum DiarizationClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func diarize(
        audioURL: URL,
        serviceURL: URL = AppConstants.diarizationServiceURL
    ) async throws -> [RawSpeakerSegment] {
        let url = serviceURL.appendingPathComponent("diarize")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let audioData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent
        let mimeType = mimeType(for: audioURL)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiarizationError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DiarizationError.badResponse(0, "No HTTP response")
        }

        if http.statusCode != 200 {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw DiarizationError.badResponse(http.statusCode, bodyString)
        }

        do {
            return try JSONDecoder()
                .decode(DiarizationResponse.self, from: data)
                .segments
        } catch {
            throw DiarizationError.decode(error.localizedDescription)
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }
}
