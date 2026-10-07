import Foundation

/// Exchanges a StoreKit signed transaction plus the installation's guest
/// secret for a session-bound Hosted bearer token. The Worker verifies the
/// transaction (Apple chain, bundle, product, expiry, revocation) and decides
/// whether this guest may use Hosted; the app never decides that itself.
///
/// Unsubscribed guests keep using the Rust guest exchange unchanged.
struct HostedSubscriptionExchange {
    var session: URLSession = .shared

    func accessToken(
        serviceURL: String,
        guestSecret: String,
        sessionID: String,
        signedTransaction: String
    ) async throws -> String {
        var request = URLRequest(url: try Self.endpoint(serviceURL: serviceURL, sessionID: sessionID))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Guest \(guestSecret)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["signedTransaction": signedTransaction])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HostedCourseAgentRuntimeError.unavailable("Hosted returned an unreadable response. Please try again.")
        }
        switch http.statusCode {
        case 200:
            struct Body: Decodable { let accessToken: String }
            guard let token = try? JSONDecoder().decode(Body.self, from: data).accessToken, !token.isEmpty else {
                throw HostedCourseAgentRuntimeError.unavailable("Hosted returned an unreadable response. Please try again.")
            }
            return token
        case 402:
            throw HostedCourseAgentRuntimeError.subscriptionRequired(
                "Hosted couldn't confirm your Learnfold Hosted subscription. Open Settings > Plan and choose Restore Purchases, or pick another agent."
            )
        case 409:
            throw HostedCourseAgentRuntimeError.subscriptionRequired(
                "This Hosted subscription is already in use on the maximum number of devices."
            )
        case 429:
            throw HostedCourseAgentRuntimeError.unavailable("Hosted connection limit reached. Please try again tomorrow.")
        case 503:
            throw HostedCourseAgentRuntimeError.unavailable("Hosted is temporarily unavailable. Please try again later.")
        default:
            throw HostedCourseAgentRuntimeError.unavailable("Hosted connection failed (\(http.statusCode)). Please try again.")
        }
    }

    /// Mirrors the Rust client: the guest endpoint is always `/guest-session`
    /// at the service origin, over HTTPS except for localhost development.
    static func endpoint(serviceURL: String, sessionID: String) throws -> URL {
        guard var components = URLComponents(string: serviceURL), let host = components.host else {
            throw HostedCourseAgentRuntimeError.unavailable("Hosted isn't configured correctly in this build.")
        }
        let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        switch components.scheme {
        case "https", "wss": components.scheme = "https"
        case "http" where local, "ws" where local: components.scheme = "http"
        default:
            throw HostedCourseAgentRuntimeError.unavailable("Hosted requires a secure connection.")
        }
        components.path = "/guest-session"
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        components.fragment = nil
        guard let url = components.url else {
            throw HostedCourseAgentRuntimeError.unavailable("Hosted isn't configured correctly in this build.")
        }
        return url
    }
}
