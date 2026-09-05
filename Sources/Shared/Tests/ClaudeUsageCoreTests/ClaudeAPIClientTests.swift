import Testing
import Foundation
@testable import ClaudeUsageCore

// Serialized because tests share the process-wide MockURLProtocol.requestHandler.
@Suite(.serialized)
struct ClaudeAPIClientTests {
    private func makeClient(cookie: String? = "sessionKey=abc123") -> ClaudeAPIClient {
        ClaudeAPIClient(cookieProvider: { cookie }, urlSession: MockURLProtocol.makeSession())
    }

    private func stub(status: Int, jsonString: String, url: URL = URL(string: "https://claude.ai/api/x")!) {
        let data = jsonString.data(using: .utf8)!
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url ?? url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    // MARK: - fetchOrganizations

    @Test func fetchOrganizationsParsesUuidAndNameIgnoringExtraFields() async throws {
        stub(status: 200, jsonString: """
        [
            {"uuid": "org-1", "name": "Acme", "unknown_field": 123},
            {"uuid": "org-2", "name": "Beta"}
        ]
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let orgs = try await client.fetchOrganizations()

        #expect(orgs.count == 2)
        #expect(orgs[0].uuid == "org-1")
        #expect(orgs[0].name == "Acme")
        #expect(orgs[1].uuid == "org-2")
        #expect(orgs[1].name == "Beta")
    }

    @Test func fetchOrganizationsSkipsMalformedEntries() async throws {
        stub(status: 200, jsonString: """
        [
            {"uuid": "org-1", "name": "Acme"},
            {"uuid": "org-2"},
            {"name": "NoUUID"}
        ]
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let orgs = try await client.fetchOrganizations()

        #expect(orgs.count == 1)
        #expect(orgs[0].uuid == "org-1")
    }

    // MARK: - fetchUsage: full response with limits[]

    @Test func fetchUsageParsesFromLimitsArray() async throws {
        stub(status: 200, jsonString: """
        {
            "five_hour": {"limit_dollars": null, "remaining_dollars": null, "used_dollars": null, "resets_at": "2026-09-05T07:49:59.934015+00:00", "utilization": 13},
            "seven_day": {"limit_dollars": null, "remaining_dollars": null, "used_dollars": null, "resets_at": "2026-09-09T23:59:59.934034+00:00", "utilization": 12},
            "limits": [
                {"group": "session", "kind": "session", "percent": 42, "resets_at": "2026-09-05T07:49:59.934015+00:00", "is_active": true, "severity": "normal", "scope": null},
                {"group": "weekly", "kind": "weekly_all", "percent": 77, "resets_at": "2026-09-09T23:59:59.934034+00:00", "is_active": false, "severity": "normal", "scope": null}
            ]
        }
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let snapshot = try await client.fetchUsage(orgUUID: "org-1")

        #expect(snapshot.session?.kind == "session")
        #expect(snapshot.session?.percent == 42)
        #expect(snapshot.session?.isActive == true)

        #expect(snapshot.weekly?.kind == "weekly_all")
        #expect(snapshot.weekly?.percent == 77)
        #expect(snapshot.weekly?.isActive == false)

        #expect(!snapshot.isStale)
        #expect(!snapshot.needsLogin)
    }

    // MARK: - fetchUsage: fallback to five_hour/seven_day when limits[] is empty

    @Test func fetchUsageFallsBackToWindowsWhenLimitsIsEmpty() async throws {
        stub(status: 200, jsonString: """
        {
            "five_hour": {"resets_at": "2026-09-05T07:49:59.934015+00:00", "utilization": 13},
            "seven_day": {"resets_at": "2026-09-09T23:59:59.934034+00:00", "utilization": 12},
            "limits": []
        }
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let snapshot = try await client.fetchUsage(orgUUID: "org-1")

        #expect(snapshot.session?.percent == 13)
        #expect(snapshot.weekly?.percent == 12)
    }

    // MARK: - fetchUsage: fallback when limits[] key is missing entirely

    @Test func fetchUsageFallsBackToWindowsWhenLimitsKeyMissing() async throws {
        stub(status: 200, jsonString: """
        {
            "five_hour": {"resets_at": "2026-09-05T07:49:59.934015+00:00", "utilization": 55}
        }
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let snapshot = try await client.fetchUsage(orgUUID: "org-1")

        #expect(snapshot.session?.percent == 55)
        #expect(snapshot.weekly == nil)
    }

    // MARK: - fetchUsage: totally empty object -> partial (nil, nil), no throw

    @Test func fetchUsageReturnsNilFieldsWithoutThrowingWhenBodyIsEmptyObject() async throws {
        stub(status: 200, jsonString: "{}")
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let snapshot = try await client.fetchUsage(orgUUID: "org-1")

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly == nil)
        #expect(!snapshot.needsLogin)
    }

    // MARK: - fetchUsage: unknown extra top-level and nested fields are ignored

    @Test func fetchUsageIgnoresUnknownFields() async throws {
        stub(status: 200, jsonString: """
        {
            "some_new_field": {"nested": true},
            "limits": [
                {"group": "session", "kind": "session", "percent": 9, "resets_at": "2026-09-05T07:49:59.934015+00:00", "is_active": true, "totally_new": "x"}
            ],
            "another_unrelated_field": 42
        }
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let snapshot = try await client.fetchUsage(orgUUID: "org-1")

        #expect(snapshot.session?.percent == 9)
        #expect(snapshot.weekly == nil)
    }

    // MARK: - Auth / HTTP errors

    @Test func fetchUsageThrowsNotLoggedInOn401() async throws {
        stub(status: 401, jsonString: "{}")
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()

        do {
            _ = try await client.fetchUsage(orgUUID: "org-1")
            Issue.record("Expected notLoggedIn to be thrown")
        } catch ClaudeAPIError.notLoggedIn {
            // expected
        } catch {
            Issue.record("Expected notLoggedIn, got \(error)")
        }
    }

    @Test func fetchUsageThrowsNotLoggedInWhenNoCookie() async throws {
        let client = makeClient(cookie: nil)

        do {
            _ = try await client.fetchUsage(orgUUID: "org-1")
            Issue.record("Expected notLoggedIn to be thrown")
        } catch ClaudeAPIError.notLoggedIn {
            // expected
        } catch {
            Issue.record("Expected notLoggedIn, got \(error)")
        }
    }

    @Test func fetchUsageThrowsHttpErrorOnServerError() async throws {
        stub(status: 500, jsonString: "{}")
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()

        do {
            _ = try await client.fetchUsage(orgUUID: "org-1")
            Issue.record("Expected httpError to be thrown")
        } catch ClaudeAPIError.httpError(let code) {
            #expect(code == 500)
        } catch {
            Issue.record("Expected httpError, got \(error)")
        }
    }

    @Test func cookieHeaderIsSentVerbatim() async throws {
        let expectedCookie = "sessionKey=abc123; other=xyz"
        let box = CapturedHeaderBox()
        MockURLProtocol.requestHandler = { request in
            box.value = request.value(forHTTPHeaderField: "Cookie")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = ClaudeAPIClient(cookieProvider: { expectedCookie }, urlSession: MockURLProtocol.makeSession())
        _ = try await client.fetchUsage(orgUUID: "org-1")

        #expect(box.value == expectedCookie)
    }
}

private final class CapturedHeaderBox: @unchecked Sendable {
    var value: String?
}
