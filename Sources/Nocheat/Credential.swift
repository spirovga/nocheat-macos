import Foundation

/// Stores the access key or sign-in session in a file only this user can read
/// (~/Library/Application Support/nocheat/credential). A plain file is used instead of the
/// keychain so the app never triggers a keychain password prompt.
enum Credential {
    /// The app's private folder, readable by this user only.
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("nocheat", isDirectory: true)
        // The app used to be called "Human or AI": keep the key and transcript saved under that name.
        let old = support.appendingPathComponent("Human or AI", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private static var url: URL { directory.appendingPathComponent("credential") }

    static func load() -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func save(_ value: String?) {
        guard let value, !value.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        FileManager.default.createFile(atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
    }
}

/// The transcript, kept on this Mac between launches
/// (~/Library/Application Support/nocheat/history.json, readable by this user only).
enum History {
    private static var url: URL { Credential.directory.appendingPathComponent("history.json") }
    /// Oldest lines are dropped beyond this, so the file cannot grow without bound.
    private static let limit = 5000

    static func load() -> [TranscriptLine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TranscriptLine].self, from: data)) ?? []
    }

    /// Saves settled text only; words still being recognised are not written.
    static func save(_ lines: [TranscriptLine]) {
        let settled = lines.filter { !$0.text.isEmpty }.suffix(limit).map { line -> TranscriptLine in
            var copy = line
            copy.interim = ""
            return copy
        }
        guard !settled.isEmpty, let data = try? JSONEncoder().encode(Array(settled)) else { return clear() }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
