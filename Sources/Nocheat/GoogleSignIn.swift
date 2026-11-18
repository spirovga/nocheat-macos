import AppKit
import AuthenticationServices
import CryptoKit

/// Google sign-in through the server, which holds the Google client secret. The browser sheet ends on
/// nocheat://auth?code=…, and the code plus our verifier are traded for a session token.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case cancelled, rejected(String), exchange

        var errorDescription: String? {
            switch self {
            case .cancelled: nil
            case .rejected(let reason): reason == "expired" ? "Sign-in took too long. Please try again." : "Google sign-in did not complete."
            case .exchange: "Could not finish signing in with the server."
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    func signIn(server: URL) async throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Self.base64url(Data(bytes))
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var start = URLComponents(url: server.appendingPathComponent("auth/google/start"), resolvingAgainstBaseURL: false)!
        start.queryItems = [URLQueryItem(name: "challenge", value: challenge)]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: start.url!, callbackURLScheme: "nocheat") { url, _ in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: Failure.cancelled) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: Failure.exchange) }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            if error == "cancelled" { throw Failure.cancelled }
            throw Failure.rejected(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw Failure.exchange }

        var request = URLRequest(url: server.appendingPathComponent("auth/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = body["token"] as? String else { throw Failure.exchange }
        return token
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
