import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// One bubble in the transcript: one sentence from one speaker.
struct TranscriptLine: Identifiable, Codable {
    var id = UUID()
    let speaker: String
    /// Settled text.
    var text: String
    /// Text still being recognised; it changes until the recogniser settles it.
    var interim = ""

    /// Pseudo-speaker for the line drawn between listening sessions; its text is the start time.
    static let divider = "divider"
}

/// The server's response-timing check: how long the candidate waits before each answer.
struct ResponseTiming: Equatable {
    let samples: Int
    let inBand: Int
    let meanSeconds: Double?
    /// True when nearly every answer begins 3 s or more after the question.
    let flagged: Bool
}

/// A finished listening session, as the server remembers it.
struct PastSession: Identifiable {
    let id: Int
    let started: Date?
    let seconds: Double
    let words: Int
    /// AI probability, 0 to 1; nil until the session has been evaluated.
    var probability: Double?
    var detail: String?
    var busy = false
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case idle, connecting, live, stopping }

    /// Where the user stands: no credential, signed in with Google but without a key yet, or ready to listen.
    enum Access: Equatable { case signedOut, waiting(pending: Bool), ready }

    /// Bearer credential: an access key typed by hand, or a Google sign-in session ("as_…").
    @Published var accessKey = Credential.load() ?? ""
    @Published var access: Access = {
        guard let saved = Credential.load() else { return .signedOut }
        return saved.hasPrefix("as_") ? .waiting(pending: false) : .ready
    }()
    @Published var email: String?
    @Published var googleAvailable = false
    @AppStorage("serverURL") var serverURL = "http://127.0.0.1:8787"
    @Published var phase = Phase.idle
    /// The transcript, restored from disk at launch.
    @Published var lines: [TranscriptLine] = History.load()
    @Published var overall: Double?
    @Published var balanceSeconds: Double?
    @Published var notice: String?
    /// True once "Request more minutes" has been sent and is waiting for approval.
    @Published var topUpRequested = false
    /// Recent finished sessions, shown in the Previous sessions window.
    @Published var recent: [PastSession] = []

    var outOfMinutes: Bool { balanceSeconds.map { $0 <= 0 } ?? false }
    /// Under five minutes left: time to warn, while there is still room to act.
    var lowBalance: Bool { balanceSeconds.map { $0 > 0 && $0 < 300 } ?? false }
    /// The detector's own wording for the latest check, e.g. "ai · high confidence".
    @Published var verdict: String?
    /// True between pressing Evaluate and the server's answer.
    @Published var evaluating = false
    @Published var timing: ResponseTiming?
    /// Bumped on every result, so the figure can replay its animation even when the value is unchanged.
    @Published var scoreTick = 0
    /// Recognition language sent to the server: "multi" detects it automatically, or a code such as "ru".
    @AppStorage("language") var language = "multi"

    private var client: StreamClient?
    private let mic = MicCapture()
    private let system = SystemAudioCapture()

    /// Loudness of each voice, for the speaking indicators.
    let levels = LevelStore()
    private let google = GoogleSignIn()
    private var usesGoogle: Bool { accessKey.hasPrefix("as_") }

    private var server: URL? { URL(string: serverURL.trimmingCharacters(in: .whitespaces)) }

    /// Checks the key with the backend and stores it on success.
    func signIn() async {
        notice = nil
        let key = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server, !key.isEmpty else { return }
        var request = URLRequest(url: server.appendingPathComponent("v1/me"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                notice = "That access key was not accepted."
                return
            }
            balanceSeconds = body["balanceSeconds"] as? Double
            accessKey = key
            Credential.save(key)
            access = .ready
        } catch {
            notice = "Cannot reach the server at \(serverURL)."
        }
    }

    func signOut() {
        stop()
        if usesGoogle, let server {
            var request = URLRequest(url: server.appendingPathComponent("auth/logout"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessKey)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }
        Credential.save(nil)
        clearHistory()
        accessKey = ""
        email = nil
        access = .signedOut
    }

    /// Asks the server whether Google sign-in is configured, to enable the button.
    func checkServer() async {
        guard let server,
              let (data, _) = try? await URLSession.shared.data(from: server.appendingPathComponent("health")),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            googleAvailable = false
            return
        }
        googleAvailable = body["google"] as? Bool ?? false
    }

    func signInWithGoogle() async {
        notice = nil
        guard let server else { return }
        do {
            let token = try await google.signIn(server: server)
            accessKey = token
            Credential.save(token)
            access = .waiting(pending: false)
            await refreshAccount()
        } catch GoogleSignIn.Failure.cancelled {
            // The user closed the sign-in window; nothing to report.
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Reloads the Google account's state; moves to the main screen once a key has been issued.
    func refreshAccount() async {
        guard usesGoogle, let server else { return }
        var request = URLRequest(url: server.appendingPathComponent("v1/account"))
        request.setValue("Bearer \(accessKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return }
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            signOut()
            notice = "Your sign-in expired. Please sign in again."
            return
        }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        email = body["email"] as? String
        balanceSeconds = body["balanceSeconds"] as? Double
        switch body["access"] as? String {
        case "active": access = .ready
        case "pending": access = .waiting(pending: true)
        default: access = .waiting(pending: false)
        }
    }

    func requestAccess() async {
        guard let server else { return }
        var request = URLRequest(url: server.appendingPathComponent("v1/account/request"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        if (try? await URLSession.shared.data(for: request)) == nil {
            notice = "Cannot reach the server at \(serverURL)."
        }
        await refreshAccount()
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest? {
        guard let server else { return nil }
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(accessKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Reloads the balance. Called on a timer while out of minutes, so a top-up unlocks the app by itself.
    func refreshBalance() async {
        guard phase == .idle, let request = request("v1/me"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = body["balanceSeconds"] as? Double else { return }
        let wasOut = outOfMinutes
        balanceSeconds = balance
        topUpRequested = body["topUpRequested"] as? Bool ?? false
        if wasOut && balance > 0 { notice = "Minutes added. You can start listening again." }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func verdict(_ m: [String: Any]) -> String {
        [m["predictedClass"] as? String, (m["confidence"] as? String).map { "\($0) confidence" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Loads the recent finished sessions with any result the server already has for them.
    func loadRecent() async {
        guard let request = request("v1/sessions"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = body["sessions"] as? [[String: Any]] else { return }
        recent = list.compactMap { s in
            guard let id = s["id"] as? Int else { return nil }
            let result = s["result"] as? [String: Any]
            return PastSession(
                id: id, started: (s["startedAt"] as? String).flatMap(Self.iso.date),
                seconds: s["secondsUsed"] as? Double ?? 0, words: s["words"] as? Int ?? 0,
                probability: result?["probability"] as? Double, detail: result.map(Self.verdict))
        }
    }

    /// Evaluates a finished session. The server answers from its cache when it already has the result.
    func evaluatePast(_ id: Int) async {
        guard let i = recent.firstIndex(where: { $0.id == id }), !recent[i].busy,
              let request = request("v1/sessions/\(id)/evaluate", method: "POST") else { return }
        recent[i].busy = true
        notice = nil
        let reply = try? await URLSession.shared.data(for: request)
        guard let j = recent.firstIndex(where: { $0.id == id }) else { return }
        recent[j].busy = false
        guard let (data, _) = reply, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            notice = "Could not reach the server to evaluate that session."
            return
        }
        if let p = body["probability"] as? Double {
            recent[j].probability = p
            recent[j].detail = Self.verdict(body)
        } else {
            notice = body["message"] as? String ?? "That session could not be evaluated."
        }
    }

    /// Sends a request for more minutes to the administrator.
    func requestMinutes() async {
        guard let request = request("v1/me/topup-request", method: "POST"),
              let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            notice = "Could not send the request. Check your connection and try again."
            return
        }
        notice = nil
        topUpRequested = true
    }

    func start() {
        guard phase == .idle, !outOfMinutes, let server else { return }
        phase = .connecting
        notice = nil
        // Earlier conversation stays on screen; a divider marks where this listening session begins.
        if !lines.isEmpty {
            for i in lines.indices { lines[i].interim = "" }
            lines.removeAll { $0.text.isEmpty && $0.speaker != TranscriptLine.divider }
            if lines.last?.speaker == TranscriptLine.divider { lines.removeLast() }
            if !lines.isEmpty {
                lines.append(TranscriptLine(speaker: TranscriptLine.divider, text: Date.now.formatted(date: .abbreviated, time: .shortened)))
            }
        }
        verdict = nil
        timing = nil
        overall = nil
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                return fail(CaptureError.microphoneDenied.localizedDescription)
            }
            let client = StreamClient(server: server, key: accessKey, language: language)
            self.client = client
            do {
                for try await message in client.messages() { await handle(message, client) }
                if phase != .idle { finish() }
            } catch {
                fail("Connection lost. Check the access key and that the server is running with speech-to-text set up.")
                await refreshBalance()
                if outOfMinutes { notice = nil }
            }
        }
    }

    /// Asks the server to check what the candidate has said so far, right now.
    func evaluate() {
        guard phase == .live, !evaluating else { return }
        evaluating = true
        notice = nil
        client?.sendEvaluate()
    }

    func stop() {
        guard phase == .live || phase == .connecting else { return }
        phase = .stopping
        stopCapture()
        client?.sendStop()
    }

    private func handle(_ m: [String: Any], _ client: StreamClient) async {
        switch m["type"] as? String {
        case "ready":
            balanceSeconds = m["balanceSeconds"] as? Double
            do {
                let levels = levels
                try mic.start {
                    levels.feed(.interviewer, $0)
                    client.sendAudio(.interviewer, $0)
                }
                try system.start {
                    levels.feed(.candidate, $0)
                    client.sendAudio(.candidate, $0)
                }
                if phase == .connecting { phase = .live }
            } catch {
                fail("Audio capture failed: \(error.localizedDescription)")
            }
        case "transcript":
            guard let speaker = m["speaker"] as? String, let text = m["text"] as? String else { return }
            ingest(speaker: speaker, text: text, final: m["final"] as? Bool ?? true)
        case "score":
            // The detector's result for the candidate's transcript so far, shown as received.
            guard let p = m["probability"] as? Double else { return }
            evaluating = false
            overall = p
            scoreTick += 1
            let label = Self.verdict(m)
            verdict = label.isEmpty ? nil : label
        case "timing":
            timing = ResponseTiming(
                samples: m["samples"] as? Int ?? 0, inBand: m["inBand"] as? Int ?? 0,
                meanSeconds: (m["meanMs"] as? Double).map { $0 / 1000 }, flagged: m["flagged"] as? Bool ?? false)
        case "balance":
            balanceSeconds = m["balanceSeconds"] as? Double
        case "notice", "error":
            evaluating = false
            if (m["code"] as? String) == "no_balance" {
                // The out-of-minutes panel explains this better than a line of text.
                balanceSeconds = 0
            } else {
                notice = m["message"] as? String
            }
        case "done":
            if let o = m["overall"] as? Double { overall = o }
            finish()
        default:
            break
        }
    }

    /// Files recognised speech into bubbles, one sentence per bubble. The recogniser often settles
    /// text mid-sentence, so a new piece continues the speaker's last bubble until that sentence ends.
    private func ingest(speaker: String, text: String, final: Bool) {
        var index = lines.lastIndex { $0.speaker == speaker }
        if let i = index {
            let unfinished = i == lines.count - 1 && !Self.endsSentence(lines[i].text)
            if lines[i].interim.isEmpty && !unfinished { index = nil }
        }
        guard final else {
            if let i = index { lines[i].interim = text } else { lines.append(TranscriptLine(speaker: speaker, text: "", interim: text)) }
            return
        }
        let settled = ((index.map { lines[$0].text } ?? "") + " " + text).trimmingCharacters(in: .whitespaces)
        var sentences = Self.sentences(settled).map { TranscriptLine(speaker: speaker, text: $0) }
        if let i = index {
            if sentences.isEmpty {
                lines[i].interim = ""
                if lines[i].text.isEmpty { lines.remove(at: i) }
                return
            }
            lines[i].text = sentences.removeFirst().text
            lines[i].interim = ""
            lines.insert(contentsOf: sentences, at: i + 1)
        } else {
            lines.append(contentsOf: sentences)
        }
        History.save(lines)
    }

    /// Saves the transcript as a plain-text file wherever the user chooses. Nothing leaves this Mac.
    func exportHistory() {
        var text = "Human or AI · transcript\n"
        var previous = ""
        for line in lines where !line.text.isEmpty {
            if line.speaker == TranscriptLine.divider {
                text += "\n———— New session · \(line.text) ————\n"
            } else {
                // Name the speaker once per turn, like the bubbles do.
                if line.speaker != previous { text += "\n\(line.speaker == "interviewer" ? "You" : "Candidate"):\n" }
                text += line.text + "\n"
            }
            previous = line.speaker
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Interview transcript \(Date.now.formatted(.iso8601.year().month().day())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            notice = "Transcript saved to \(url.lastPathComponent)."
        } catch {
            notice = "Could not save the transcript: \(error.localizedDescription)"
        }
    }

    /// Removes the transcript from the screen and from disk.
    func clearHistory() {
        lines = []
        History.clear()
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]

    private static func endsSentence(_ text: String) -> Bool {
        text.last.map(terminators.contains) ?? false
    }

    /// Splits after ".", "!", "?" or "…" when a space follows, so "3.5" and "e.g" stay intact.
    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            if terminators.contains(c), i + 1 < chars.count, chars[i + 1] == " " {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    private func stopCapture() {
        mic.stop()
        system.stop()
        levels.reset()
    }

    private func finish() {
        stopCapture()
        client?.cancel()
        client = nil
        evaluating = false
        phase = .idle
    }

    private func fail(_ message: String) {
        finish()
        notice = message
    }
}
