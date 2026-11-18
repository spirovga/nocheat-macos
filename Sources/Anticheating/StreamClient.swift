import Foundation

/// Websocket connection to the backend's /v1/stream endpoint.
final class StreamClient: @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(server: URL, key: String, language: String) {
        var components = URLComponents(url: server.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false)!
        components.scheme = server.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "language", value: language)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
    }

    /// Yields decoded JSON messages until the server closes the connection.
    func messages() -> AsyncThrowingStream<[String: Any], Error> {
        task.resume()
        return AsyncThrowingStream { continuation in
            @Sendable func next() {
                task.receive { result in
                    switch result {
                    case .failure(let error):
                        continuation.finish(throwing: self.task.closeCode == .invalid ? error : nil)
                    case .success(let message):
                        if case .string(let text) = message,
                           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                            continuation.yield(object)
                        }
                        next()
                    }
                }
            }
            next()
        }
    }

    func sendAudio(_ channel: Channel, _ pcm: Data) {
        var frame = Data([channel.rawValue])
        frame.append(pcm)
        task.send(.data(frame)) { _ in }
    }

    func sendEvaluate() {
        task.send(.string(#"{"type":"evaluate"}"#)) { _ in }
    }

    func sendStop() {
        task.send(.string(#"{"type":"stop"}"#)) { _ in }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
