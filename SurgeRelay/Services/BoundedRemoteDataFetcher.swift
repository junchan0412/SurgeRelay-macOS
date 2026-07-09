import Darwin
import Foundation

enum BoundedRemoteFetchError: LocalizedError, Equatable {
    case invalidSourceURL
    case blockedPrivateAddress(String)
    case responseTooLarge(maximumSize: Int)
    case httpFailure(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            "来源地址无效。"
        case let .blockedPrivateAddress(host):
            "来源地址指向本机、内网或保留地址，已拦截：\(host)"
        case let .responseTooLarge(maximumSize):
            "来源响应超过限制（最多 \(ByteCountFormatter.string(fromByteCount: Int64(maximumSize), countStyle: .file))）。"
        case let .httpFailure(status, message):
            message.isEmpty ? "来源返回 HTTP \(status)。" : "来源返回 HTTP \(status)：\(message)"
        }
    }
}

struct BoundedRemoteDataFetcher {
    static let sourceNameLookup = BoundedRemoteDataFetcher(
        maximumResponseSize: 256 * 1024,
        timeoutInterval: 10
    )

    var maximumResponseSize: Int
    var timeoutInterval: TimeInterval
    var configuration: URLSessionConfiguration

    init(
        maximumResponseSize: Int,
        timeoutInterval: TimeInterval,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.maximumResponseSize = maximumResponseSize
        self.timeoutInterval = timeoutInterval
        self.configuration = configuration
    }

    func data(for request: URLRequest) async throws -> Data {
        try Self.validateRemoteRequest(request)
        var request = request
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeoutInterval

        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        let delegate = BoundedRemoteDataDelegate(maximumSize: maximumResponseSize)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await delegate.data(for: request, session: session)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BoundedRemoteFetchError.httpFailure(
                status: http.statusCode,
                message: String(Self.decode(data).prefix(240))
            )
        }
        return data
    }

    static func validateRemoteRequest(_ request: URLRequest) throws {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            throw BoundedRemoteFetchError.invalidSourceURL
        }
        guard !isPrivateNetworkHost(host) else {
            throw BoundedRemoteFetchError.blockedPrivateAddress(host)
        }
    }

    static func isPrivateNetworkHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized.hasSuffix(".local") {
            return true
        }
        if let ipv4 = parseIPv4(normalized) {
            return isPrivateIPv4(ipv4)
        }
        if let ipv6 = parseIPv6(normalized) {
            return isPrivateIPv6(ipv6)
        }
        return resolvesToPrivateAddress(normalized)
    }

    private static func parseIPv4(_ host: String) -> UInt32? {
        var address = in_addr()
        let result = host.withCString { inet_pton(AF_INET, $0, &address) }
        guard result == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0.prefix(16)) }
    }

    private static func resolvesToPrivateAddress(_ host: String) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return false
        }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor?.pointee {
            if info.ai_family == AF_INET,
               let address = info.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee.sin_addr }) {
                if isPrivateIPv4(UInt32(bigEndian: address.s_addr)) { return true }
            } else if info.ai_family == AF_INET6,
                      let address = info.ai_addr?.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { $0.pointee.sin6_addr }) {
                let bytes = withUnsafeBytes(of: address) { Array($0.prefix(16)) }
                if isPrivateIPv6(bytes) { return true }
            }
            cursor = info.ai_next
        }
        return false
    }

    private static func isPrivateIPv4(_ value: UInt32) -> Bool {
        let first = Int((value >> 24) & 0xff)
        let second = Int((value >> 16) & 0xff)
        let third = Int((value >> 8) & 0xff)

        if first == 0 || first == 10 || first == 127 || first >= 224 { return true }
        if first == 100 && (64...127).contains(second) { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 192 && second == 0 && third == 0 { return true }
        if first == 198 && (18...19).contains(second) { return true }
        if first == 203 && second == 0 && third == 113 { return true }
        return false
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] & 0xfe == 0xfc { return true }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
        if bytes[0] == 0xff { return true }
        return false
    }

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }
}

private final class BoundedRemoteDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumSize: Int
    private let lock = NSLock()
    private var storedData = Data()
    private var storedResponse: URLResponse?
    private var completion: ((Result<(Data, URLResponse), Error>) -> Void)?
    private var isCompleted = false

    init(maximumSize: Int) {
        self.maximumSize = maximumSize
    }

    func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.withLock {
                self.completion = { result in
                    continuation.resume(with: result)
                }
            }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if response.expectedContentLength > Int64(maximumSize) {
            finish(.failure(BoundedRemoteFetchError.responseTooLarge(maximumSize: maximumSize)))
            completionHandler(.cancel)
            return
        }
        lock.withLock {
            storedResponse = response
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceedsLimit = lock.withLock { () -> Bool in
            storedData.append(data)
            return storedData.count > maximumSize
        }
        if exceedsLimit {
            finish(.failure(BoundedRemoteFetchError.responseTooLarge(maximumSize: maximumSize)))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !isCancellationAfterExplicitFailure(error) {
            finish(.failure(error))
            return
        }
        let result = lock.withLock { () -> Result<(Data, URLResponse), Error> in
            guard let response = storedResponse else {
                return .failure(URLError(.badServerResponse))
            }
            return .success((storedData, response))
        }
        finish(result)
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        let completion = lock.withLock { () -> ((Result<(Data, URLResponse), Error>) -> Void)? in
            guard !isCompleted else { return nil }
            isCompleted = true
            let completion = self.completion
            self.completion = nil
            return completion
        }
        completion?(result)
    }

    private func isCancellationAfterExplicitFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain &&
            nsError.code == NSURLErrorCancelled &&
            lock.withLock { isCompleted }
    }
}
