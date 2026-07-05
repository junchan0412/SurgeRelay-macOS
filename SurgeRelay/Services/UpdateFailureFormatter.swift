import Foundation

enum UpdateFailureFormatter {
    static func detailedMessage(
        for error: any Error,
        sourceURL: String? = nil,
        sourceCheckError: (any Error)? = nil
    ) -> String {
        let primary = baseMessage(for: error, sourceURL: sourceURL)
        guard let sourceCheckError,
              isActionableNetworkFailure(sourceCheckError),
              !isActionableNetworkFailure(error) else {
            return primary
        }

        let sourceMessage = baseMessage(for: sourceCheckError, sourceURL: sourceURL)
        guard sourceMessage != primary else { return primary }
        return "\(sourceMessage)\n转换阶段同时失败：\(primary)"
    }

    static func summary(from message: String, maxLength: Int = 42) -> String {
        let oneLine = message
            .components(separatedBy: .newlines)
            .first?
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard oneLine.count > maxLength else { return oneLine }
        return "\(oneLine.prefix(max(1, maxLength - 1)))…"
    }

    static func isActionableNetworkFailure(_ error: any Error) -> Bool {
        if let relayError = error as? RelayError,
           case .httpFailure = relayError {
            return true
        }
        if error is URLError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    private static func baseMessage(for error: any Error, sourceURL: String?) -> String {
        if let relayError = error as? RelayError {
            switch relayError {
            case let .httpFailure(status, message):
                return httpFailureMessage(status: status, message: message, sourceURL: sourceURL)
            default:
                return relayError.localizedDescription
            }
        }

        if let urlError = error as? URLError {
            return urlErrorMessage(urlError, sourceURL: sourceURL)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return urlErrorMessage(URLError(URLError.Code(rawValue: nsError.code)), sourceURL: sourceURL)
        }

        return error.localizedDescription
    }

    private static func httpFailureMessage(status: Int, message: String, sourceURL: String?) -> String {
        let target = sourceTargetDescription(sourceURL)
        let statusText = httpStatusText(status)
        let base = switch status {
        case 404:
            "原始链接返回 \(statusText)\(target)，请检查文件是否已删除、改名、分支/路径是否变化，或仓库是否公开且当前链接有访问权限。"
        case 401:
            "原始链接返回 \(statusText)\(target)，请检查是否需要登录、Token 或访问权限。"
        case 403:
            "原始链接返回 \(statusText)\(target)，可能是仓库权限、访问频率限制或防盗链限制。"
        case 429:
            "原始链接返回 \(statusText)\(target)，请求过于频繁，请稍后重试。"
        case 500..<600:
            "原始服务器返回 \(statusText)\(target)，请稍后重试。"
        default:
            "原始链接请求失败：\(statusText)\(target)。"
        }

        let body = cleanedHTTPBody(message)
        guard !body.isEmpty else { return base }
        return "\(base)\n服务器返回：\(body)"
    }

    private static func urlErrorMessage(_ error: URLError, sourceURL: String?) -> String {
        let target = sourceTargetDescription(sourceURL)
        switch error.code {
        case .timedOut:
            return "连接原始链接超时\(target)，请稍后重试或检查网络。"
        case .cannotFindHost, .dnsLookupFailed:
            return "无法解析原始链接域名\(target)，请检查链接或 DNS。"
        case .cannotConnectToHost, .networkConnectionLost:
            return "无法连接原始链接\(target)，请检查网络后重试。"
        case .notConnectedToInternet:
            return "当前网络不可用，无法访问原始链接\(target)。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "原始链接的 HTTPS 证书校验失败\(target)。"
        case .badURL, .unsupportedURL:
            return "原始链接格式无效\(target)。"
        default:
            return "无法访问原始链接\(target)：\(error.localizedDescription)"
        }
    }

    private static func sourceTargetDescription(_ sourceURL: String?) -> String {
        guard let sourceURL,
              !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return "：\(redactedSourceURL(sourceURL))"
    }

    private static func redactedSourceURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }

    private static func httpStatusText(_ status: Int) -> String {
        let phrase = switch status {
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: HTTPURLResponse.localizedString(forStatusCode: status)
        }
        return "\(status)（\(phrase)）"
    }

    private static func cleanedHTTPBody(_ message: String) -> String {
        let trimmed = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased().hasPrefix("<!doctype html") || trimmed.lowercased().hasPrefix("<html") {
            return "HTML 错误页"
        }
        return String(trimmed.prefix(240))
    }
}
