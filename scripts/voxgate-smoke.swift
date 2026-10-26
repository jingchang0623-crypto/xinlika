import Foundation

/// Compile with Sources/LuyinbiCore/OggWrap.swift to exercise the App's audio container path.
@main
struct VoxgateSmoke {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func main() async {
        do {
            try await execute()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func execute() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--cb08-raw") else {
            throw Failure(message: "Usage: voxgate-smoke CONFIG_JSON AUDIO OUTPUT_JSON [--cb08-raw]")
        }
        let configData = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let server = config["server"] as? [String: Any],
              server["host"] as? String == "127.0.0.1",
              let port = server["port"] as? Int,
              let token = server["auth_token"] as? String, !token.isEmpty,
              let endpoint = URL(string: "http://127.0.0.1:\(port)/v1/audio/transcriptions") else {
            throw Failure(message: "Expected authenticated loopback evaluation configuration")
        }
        let input = URL(fileURLWithPath: arguments[1])
        var audio = try Data(contentsOf: input)
        let raw = arguments.count == 4
        var audioSeconds: Double?
        if raw {
            guard !audio.isEmpty, audio.count % OggWrap.packetLen == 0 else {
                throw Failure(message: "Incomplete CB08 packet; refusing to trim or upload")
            }
            audioSeconds = OggWrap.durationSeconds(rawLength: audio.count)
            audio = Data(try OggWrap.wrap([UInt8](audio)))
        }
        let ogg = raw || input.pathExtension.lowercased() == "ogg"
        let filename = raw ? "cb08-fixture.ogg" : input.lastPathComponent
        let boundary = "Shennao-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (key, value) in [("model", "voxgate"), ("response_format", "json")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(ogg ? "audio/ogg" : "audio/wav")\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 330
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let start = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = try JSONSerialization.jsonObject(with: data)
        var result: [String: Any] = ["http_status": status, "elapsed_seconds": elapsed,
                                     "audio_bytes": audio.count, "uses_shared_ogg_wrap": raw,
                                     "response": payload]
        if let audioSeconds { result["source_audio_seconds"] = audioSeconds }
        let output = URL(fileURLWithPath: arguments[2])
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
        guard status == 200, let json = payload as? [String: Any],
              let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Transcription failed (HTTP \(status)); see \(output.path)")
        }
        print("HTTP \(status), \(String(format: "%.3f", elapsed))s, \(audio.count) audio bytes, \(text.count) characters")
        print("Result: \(output.path)")
    }
}
