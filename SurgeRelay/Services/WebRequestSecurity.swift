import Foundation

enum WebRequestSecurity {
    static let sessionCookieName = "SurgeRelayWebSession"

    static func rejection(for request: WebHTTPRequest, configuration: WebServerConfiguration) -> WebHTTPResponse? {
        if !configuration.allowRemoteAccess && !request.isLoopback {
            return .error(status: 403, message: "Web 管理仅允许从本机访问。")
        }
        guard request.path.hasPrefix("/api/") else { return nil }
        if isUnsafeMethod(request.method), !isTrustedOrigin(request) {
            return .error(status: 403, message: "Web 管理拒绝跨来源请求。")
        }
        guard isAuthorized(request, configuration: configuration) else {
            return .error(status: 401, message: "Web 管理访问令牌无效或缺失。")
        }
        return nil
    }

    static func isAuthorized(_ request: WebHTTPRequest, configuration: WebServerConfiguration) -> Bool {
        let expected = configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }
        if let provided = bearerAccessToken(in: request),
           timingSafeEqual(provided, expected) {
            return true
        }
        if allowsAccessTokenBootstrap(request),
           let provided = bootstrapAccessToken(in: request),
           timingSafeEqual(provided, expected) {
            return true
        }
        guard let session = sessionCookie(in: request) else { return false }
        return timingSafeEqual(session, sessionCookieValue(for: expected))
    }

    static func sessionCookieHeader(configuration: WebServerConfiguration) -> String {
        sessionCookieHeader(accessToken: configuration.accessToken)
    }

    static func sessionCookieHeader(accessToken: String) -> String {
        let value = sessionCookieValue(for: accessToken)
        return "\(sessionCookieName)=\(value); Path=/api; HttpOnly; SameSite=Strict; Max-Age=2592000"
    }

    static func sessionCookieValue(for accessToken: String) -> String {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return Data("surge-relay-web-session-v1:\(token)".utf8).sha256String
    }

    private static func allowsAccessTokenBootstrap(_ request: WebHTTPRequest) -> Bool {
        request.method == "POST" && request.path == "/api/session"
    }

    private static func isUnsafeMethod(_ method: String) -> Bool {
        ["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased())
    }

    private static func isTrustedOrigin(_ request: WebHTTPRequest) -> Bool {
        if let origin = request.headers["origin"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty {
            return isSameOrigin(origin, host: request.headers["host"])
        }
        if let referer = request.headers["referer"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !referer.isEmpty {
            return isSameOrigin(referer, host: request.headers["host"])
        }
        return bearerAccessToken(in: request) != nil
    }

    private static func isSameOrigin(_ value: String, host: String?) -> Bool {
        guard value.lowercased() != "null",
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let sourceHost = components.host?.lowercased(),
              let expected = normalizedHostPort(from: host) else {
            return false
        }
        let sourcePort = components.port ?? 80
        let expectedPort = expected.port ?? 80
        return sourceHost == expected.host && sourcePort == expectedPort
    }

    private static func bearerAccessToken(in request: WebHTTPRequest) -> String? {
        guard let authorization = request.headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              authorization.lowercased().hasPrefix("bearer ") else {
            return nil
        }
        let token = String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func bootstrapAccessToken(in request: WebHTTPRequest) -> String? {
        if let token = bearerAccessToken(in: request) {
            return token
        }
        if let value = request.query["token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = request.headers["x-surge-relay-token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }

    private static func normalizedHostPort(from value: String?) -> (host: String, port: Int?)? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let components = URLComponents(string: "http://\(value)"),
              let host = components.host?.lowercased() else {
            return nil
        }
        return (host, components.port)
    }

    private static func sessionCookie(in request: WebHTTPRequest) -> String? {
        guard let cookie = request.headers["cookie"] else { return nil }
        let values = cookie
            .split(separator: ";")
            .compactMap { item -> (String, String)? in
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (
                    parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        return values.first(where: { $0.0 == sessionCookieName })?.1
    }

    private static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            difference |= Int((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
        }
        return difference == 0
    }
}
