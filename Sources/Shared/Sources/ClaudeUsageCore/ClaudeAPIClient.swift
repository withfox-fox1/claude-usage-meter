import Foundation

public enum ClaudeAPIError: Error {
    case notLoggedIn
    case httpError(Int)
    case decodingFailed
    case network(Error)
}

/// Thin client around the (undocumented) claude.ai internal API used to read
/// plan usage limits. Authentication is entirely cookie-based: the caller
/// supplies a closure that returns the current `Cookie` header value (or nil
/// if there is no session yet); this type never manages login/cookie
/// acquisition itself.
public final class ClaudeAPIClient {
    private let cookieProvider: () -> String?
    private let urlSession: URLSession
    private let baseURL = URL(string: "https://claude.ai/api")!

    public init(cookieProvider: @escaping () -> String?, urlSession: URLSession = .shared) {
        self.cookieProvider = cookieProvider
        self.urlSession = urlSession
    }

    public func fetchOrganizations() async throws -> [(uuid: String, name: String)] {
        let data = try await performRequest(path: "organizations")

        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw ClaudeAPIError.decodingFailed
        }

        return array.compactMap { element in
            guard let uuid = element["uuid"] as? String, let name = element["name"] as? String else {
                return nil
            }
            return (uuid: uuid, name: name)
        }
    }

    /// Fetches and parses the usage snapshot for the given organization.
    ///
    /// Robustness note: the claude.ai response shape may evolve, so this
    /// never throws on a parsing problem once the HTTP call itself has
    /// succeeded — it always returns the best `UsageSnapshot` it can build
    /// (possibly with `session`/`weekly` set to nil individually) rather
    /// than failing the whole fetch because of one malformed/missing field.
    public func fetchUsage(orgUUID: String) async throws -> UsageSnapshot {
        let data = try await performRequest(path: "organizations/\(orgUUID)/usage")

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeAPIError.decodingFailed
        }

        let session = Self.extractLimit(json: json, preferredKind: "session", fallbackWindowKey: "five_hour")
        let weekly = Self.extractLimit(json: json, preferredKind: "weekly_all", fallbackWindowKey: "seven_day")

        return UsageSnapshot(session: session, weekly: weekly, fetchedAt: Date(), isStale: false, needsLogin: false)
    }

    // MARK: - Request plumbing

    private func performRequest(path: String) async throws -> Data {
        guard let cookie = cookieProvider() else {
            throw ClaudeAPIError.notLoggedIn
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ClaudeAPIError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.decodingFailed
        }

        if httpResponse.statusCode == 401 {
            throw ClaudeAPIError.notLoggedIn
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClaudeAPIError.httpError(httpResponse.statusCode)
        }

        return data
    }

    // MARK: - Lenient parsing

    /// Tries `limits[].kind == preferredKind` first, then falls back to the
    /// `five_hour`/`seven_day` top-level window objects. Returns nil (rather
    /// than throwing) if neither source yields a usable percent + resetsAt.
    private static func extractLimit(json: [String: Any], preferredKind: String, fallbackWindowKey: String) -> UsageLimit? {
        if let limits = json["limits"] as? [[String: Any]],
           let match = limits.first(where: { ($0["kind"] as? String) == preferredKind }),
           let percent = intValue(match["percent"]),
           let resetsAt = dateValue(match["resets_at"]) {
            let isActive = match["is_active"] as? Bool ?? false
            return UsageLimit(kind: preferredKind, percent: percent, resetsAt: resetsAt, isActive: isActive)
        }

        if let window = json[fallbackWindowKey] as? [String: Any],
           let percent = intValue(window["utilization"]),
           let resetsAt = dateValue(window["resets_at"]) {
            // The fallback windows don't carry an explicit is_active flag;
            // treat a present, well-formed window as active.
            return UsageLimit(kind: preferredKind, percent: percent, resetsAt: resetsAt, isActive: true)
        }

        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int {
            return value
        }
        if let value = any as? NSNumber {
            return value.intValue
        }
        if let value = any as? Double {
            return Int(value)
        }
        return nil
    }

    private static func dateValue(_ any: Any?) -> Date? {
        guard let string = any as? String else { return nil }
        return ISO8601DateParsing.parse(string)
    }
}
