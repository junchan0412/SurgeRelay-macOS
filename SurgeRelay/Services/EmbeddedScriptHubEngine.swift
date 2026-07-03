@preconcurrency import JavaScriptCore
import Darwin
import Foundation

actor EmbeddedScriptHubEngine {
    private final class BoundedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let maximumSize: Int
        private let semaphore: DispatchSemaphore
        private var storedData = Data()
        private var storedResponse: URLResponse?
        private var storedError: Error?

        init(maximumSize: Int, semaphore: DispatchSemaphore) {
            self.maximumSize = maximumSize
            self.semaphore = semaphore
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            lock.lock()
            storedResponse = response
            let expectedLength = response.expectedContentLength
            if expectedLength > maximumSize {
                storedError = RelayError.invalidOutput("Script-Hub HTTP bridge 响应超过 20 MB 限制。")
                lock.unlock()
                completionHandler(.cancel)
            } else {
                lock.unlock()
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            storedData.append(data)
            let exceedsLimit = storedData.count > maximumSize
            if exceedsLimit {
                storedError = RelayError.invalidOutput("Script-Hub HTTP bridge 响应超过 20 MB 限制。")
            }
            lock.unlock()
            if exceedsLimit {
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            if storedError == nil {
                storedError = error
            }
            lock.unlock()
            semaphore.signal()
        }

        func get() -> (Data?, URLResponse?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (storedData, storedResponse, storedError)
        }
    }

    private static let maximumHTTPBridgeResponseSize = 20 * 1024 * 1024

    func convert(script: String, scriptConverterScript: String? = nil, requestURL: URL) throws -> String {
        try Self.execute(
            script: script,
            scriptConverterScript: scriptConverterScript,
            requestURL: requestURL
        )
    }

    private static func execute(
        script: String,
        scriptConverterScript: String?,
        requestURL: URL
    ) throws -> String {
        guard let context = JSContext() else {
            throw RelayError.invalidOutput("无法创建 JavaScriptCore 运行环境。")
        }

        var output: String?
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }

        typealias HTTPBlock = @convention(block) (String, JSValue, JSValue) -> Void
        let httpBlock: HTTPBlock = { method, requestValue, callback in
            do {
                let request = try Self.makeRequest(method: method, value: requestValue)
                if request.url?.host == "script.hub",
                   request.url?.path.contains("/convert/_start_/") == true,
                   let scriptConverterScript {
                    let body = try Self.execute(
                        script: scriptConverterScript,
                        scriptConverterScript: nil,
                        requestURL: request.url!
                    )
                    callback.call(withArguments: [
                        NSNull(),
                        ["status": 200, "statusCode": 200, "headers": [:]],
                        body
                    ])
                    return
                }
                let (data, response) = try Self.performSynchronously(request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let headers = http?.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                    result[String(describing: entry.key)] = String(describing: entry.value)
                } ?? [:]
                let body = Self.decode(data)
                callback.call(withArguments: [NSNull(), ["status": status, "statusCode": status, "headers": headers], body])
            } catch {
                callback.call(withArguments: [String(reflecting: error), NSNull(), ""])
            }
        }
        context.setObject(httpBlock, forKeyedSubscript: "__relayHTTP" as NSString)

        typealias ReadBlock = @convention(block) (String) -> Any
        let readBlock: ReadBlock = { _ in NSNull() }
        context.setObject(readBlock, forKeyedSubscript: "__relayRead" as NSString)

        typealias WriteBlock = @convention(block) (String, String) -> Bool
        let writeBlock: WriteBlock = { _, _ in true }
        context.setObject(writeBlock, forKeyedSubscript: "__relayWrite" as NSString)

        typealias DoneBlock = @convention(block) (JSValue) -> Void
        let doneBlock: DoneBlock = { value in
            let response = value.forProperty("response")
            if let response, !response.isUndefined, !response.isNull {
                output = response.forProperty("body")?.toString()
            } else {
                output = value.forProperty("body")?.toString()
            }
        }
        context.setObject(doneBlock, forKeyedSubscript: "__relayDone" as NSString)

        let encodedURL = try Self.javascriptString(requestURL.absoluteString)
        context.evaluateScript(
            """
            var $environment = {"surge-version":"Surge Relay 0.1"};
            var $request = {url: \(encodedURL), method: "GET", headers: {"User-Agent":"SurgeRelay/0.1"}};
            var $httpClient = {
              get: function(request, callback) { __relayHTTP("GET", request, callback); },
              post: function(request, callback) { __relayHTTP("POST", request, callback); },
              put: function(request, callback) { __relayHTTP("PUT", request, callback); },
              delete: function(request, callback) { __relayHTTP("DELETE", request, callback); }
            };
            var $persistentStore = {
              read: function(key) { return __relayRead(key); },
              write: function(value, key) { return __relayWrite(value, key); }
            };
            var $notification = {post: function() {}};
            var $done = function(value) { __relayDone(value || {}); };
            var setTimeout = function() { return 0; };
            var clearTimeout = function() {};
            var console = {log: function(){}, warn: function(){}, error: function(){}};
            """
        )

        context.evaluateScript(script)
        let deadline = Date().addingTimeInterval(10)
        while output == nil, exceptionMessage == nil, Date() < deadline {
            context.evaluateScript("void 0")
            Thread.sleep(forTimeInterval: 0.001)
        }

        if let exceptionMessage {
            throw RelayError.invalidOutput("Script-Hub 执行异常：\(exceptionMessage)")
        }
        guard let output else {
            throw RelayError.invalidOutput("Script-Hub 内置引擎未在限定时间内返回结果。")
        }
        return output
    }

    private static func makeRequest(method: String, value: JSValue) throws -> URLRequest {
        let urlString: String
        if value.isString {
            urlString = value.toString()
        } else {
            urlString = value.forProperty("url")?.toString() ?? ""
        }
        guard let url = URL(string: urlString) else { throw RelayError.invalidSourceURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = method
        if !value.isString {
            if let headers = value.forProperty("headers")?.toDictionary() as? [String: Any] {
                for (key, value) in headers { request.setValue(String(describing: value), forHTTPHeaderField: key) }
            }
            if let body = value.forProperty("body")?.toString(), !body.isEmpty {
                request.httpBody = Data(body.utf8)
            }
        }
        request.setValue(request.value(forHTTPHeaderField: "User-Agent") ?? "SurgeRelay/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func performSynchronously(_ request: URLRequest) throws -> (Data, URLResponse) {
        for attempt in 0..<3 {
            do {
                return try performOnce(request)
            } catch {
                guard attempt < 2, isTransientNetworkError(error) else { throw error }
                Thread.sleep(forTimeInterval: [0.25, 0.75][attempt])
            }
        }
        throw URLError(.unknown)
    }

    private static func performOnce(_ request: URLRequest) throws -> (Data, URLResponse) {
        try validateNetworkRequest(request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        let semaphore = DispatchSemaphore(value: 0)
        let result = BoundedResponse(maximumSize: maximumHTTPBridgeResponseSize, semaphore: semaphore)
        let session = URLSession(configuration: configuration, delegate: result, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        guard semaphore.wait(timeout: .now() + request.timeoutInterval + 2) == .success else {
            task.cancel()
            throw URLError(.timedOut)
        }
        let (data, response, error) = result.get()
        if let error { throw error }
        guard let data, let response else { throw URLError(.badServerResponse) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RelayError.httpFailure(status: http.statusCode, message: String(Self.decode(data).prefix(240)))
        }
        return (data, response)
    }

    private static func validateNetworkRequest(_ request: URLRequest) throws {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            throw RelayError.invalidSourceURL
        }
        guard !isPrivateNetworkHost(host) else {
            throw RelayError.invalidOutput("Script-Hub HTTP bridge 已拦截本机或内网地址：\(host)")
        }
    }

    private static func isPrivateNetworkHost(_ host: String) -> Bool {
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

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        let code = URLError.Code(rawValue: (error as NSError).code)
        return (error as NSError).domain == NSURLErrorDomain && [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable,
            .secureConnectionFailed
        ].contains(code)
    }

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func javascriptString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
