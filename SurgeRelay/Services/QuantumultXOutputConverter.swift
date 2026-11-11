import Foundation

enum QuantumultXOutputConverter {
    enum ScriptContent {
        case remote(URL, argument: String?)
        case inline(String)
        case response(URL, status: Int, headers: [String: String])
    }

    struct Script {
        var placeholder: String
        var content: ScriptContent
    }

    static func normalizingRuleSource(_ content: String) -> String {
        content.components(separatedBy: "\n").map { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.contains(":"), value.range(of: #"^[0-9A-Fa-f:]+/[0-9]{1,3}$"#, options: .regularExpression) != nil else { return line }
            return "IP-CIDR6,\(value)" + (line.hasSuffix("\r") ? "\r" : "")
        }.joined(separator: "\n")
    }

    static func ruleSet(_ content: String, policy: String) throws -> String {
        let targetPolicy = policy.trimmingCharacters(in: .whitespacesAndNewlines)
        let types = ["DOMAIN": "host", "DOMAIN-SUFFIX": "host-suffix", "DOMAIN-KEYWORD": "host-keyword",
            "IP-CIDR": "ip-cidr", "IP-CIDR6": "ip6-cidr", "GEOIP": "geoip", "USER-AGENT": "user-agent", "FINAL": "final"]
        var lines: [String] = []
        for (index, line) in content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("#") || value.hasPrefix(";") || value.hasPrefix("//") { continue }
            let parts = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let type = types[parts[0].uppercased()],
                  parts.dropFirst(2).allSatisfy({ $0.lowercased() == "no-resolve" }) else {
                let hint = parts.first?.uppercased() == "URL-REGEX" ? "URL 重写请使用模块转换。" : ""
                throw RelayError.invalidOutput("Quantumult X 规则集不支持第 \(index + 1) 行：\(value)。\(hint)")
            }
            let policy = targetPolicy.uppercased() == "DIRECT" || targetPolicy.uppercased() == "REJECT" ? targetPolicy.lowercased() : targetPolicy
            lines.append(type == "final" ? "final, \(policy)" : "\(type), \(parts[1]), \(policy)")
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    static func convert(_ content: String) throws -> (content: String, scripts: [Script]) {
        var sections: [String: [String]] = [:]
        var order: [String] = []
        var scripts: [Script] = []
        var section = ""
        func append(_ line: String, to name: String) {
            if sections[name] == nil { sections[name] = []; order.append(name) }
            sections[name, default: []].append(line)
        }
        func script(_ body: ScriptContent, pattern: String, direction: String, requiresBody: Bool) {
            let placeholder = "https://relay.invalid/qx-script-\(scripts.count + 1).js"
            scripts.append(Script(placeholder: placeholder, content: body))
            append("\(pattern) url script-\(direction)-\(requiresBody ? "body" : "header") \(placeholder)", to: "rewrite_local")
        }
        for (offset, raw) in content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            func unsupported(_ detail: String) -> RelayError {
                .invalidOutput("Quantumult X 转换不支持第 \(offset + 1) 行 [\(section)]：\(detail)")
            }
            switch section {
            case "rule":
                let parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let kind = parts.first else { continue }
                if kind.uppercased() == "URL-REGEX", parts.count == 3, parts[2].uppercased().hasPrefix("REJECT") {
                    let action = parts[2].uppercased() == "REJECT" ? "reject" : "reject-img"
                    append("\(parts[1]) url \(action)", to: "rewrite_local")
                    continue
                }
                let types = ["DOMAIN": "host", "DOMAIN-SUFFIX": "host-suffix", "DOMAIN-KEYWORD": "host-keyword",
                    "IP-CIDR": "ip-cidr", "IP-CIDR6": "ip6-cidr", "GEOIP": "geoip", "USER-AGENT": "user-agent", "FINAL": "final"]
                guard let mapped = types[kind.uppercased()], parts.count >= (mapped == "final" ? 2 : 3),
                      parts.dropFirst(mapped == "final" ? 2 : 3).allSatisfy({ $0.lowercased() == "no-resolve" }) else {
                    throw unsupported(line)
                }
                let values = parts.dropFirst().filter { $0.lowercased() != "no-resolve" }.map { value in
                    value.uppercased() == "DIRECT" || value.uppercased() == "REJECT" ? value.lowercased() : value
                }
                append(([mapped] + values).joined(separator: ", "), to: "filter_local")
            case "url rewrite", "rewrite":
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count == 3 else { throw unsupported(line) }
                let action = parts[2].lowercased()
                if ["302", "307", "reject", "reject-200", "reject-dict", "reject-array", "reject-img", "reject-video"].contains(action) {
                    append("\(parts[0]) url \(action)" + (action == "302" || action == "307" ? " \(parts[1])" : ""), to: "rewrite_local")
                } else if action == "header" {
                    let body = "$done({url: $request.url.replace(new RegExp(\(try literal(parts[0]))), \(try literal(parts[1])))});"
                    script(.inline(body), pattern: parts[0], direction: "request", requiresBody: false)
                } else { throw unsupported(line) }
            case "script":
                let values = namedValues(in: line)
                guard let kind = values["type"], let address = values["script-path"],
                      let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) else {
                    throw unsupported(line)
                }
                if kind == "cron", let cron = values["cronexp"] ?? values["cronexpr"] {
                    let placeholder = "https://relay.invalid/qx-script-\(scripts.count + 1).js"
                    scripts.append(Script(placeholder: placeholder, content: .remote(url, argument: values["argument"])))
                    append("\(cron) \(placeholder)", to: "task_local")
                } else if ["http-request", "http-response"].contains(kind), let pattern = values["pattern"] {
                    let needsBody = ["true", "1"].contains(values["requires-body"]?.lowercased() ?? "") ||
                        ["true", "1"].contains(values["binary-body-mode"]?.lowercased() ?? "")
                    script(.remote(url, argument: values["argument"]), pattern: pattern,
                        direction: kind == "http-request" ? "request" : "response", requiresBody: needsBody)
                } else { throw unsupported(line) }
            case "mitm":
                guard let equal = line.firstIndex(of: "="), line[..<equal].trimmingCharacters(in: .whitespaces).lowercased() == "hostname" else {
                    throw unsupported(line)
                }
                let hosts = line[line.index(after: equal)...].replacingOccurrences(of: "%APPEND%", with: "")
                    .replacingOccurrences(of: "%INSERT%", with: "").trimmingCharacters(in: .whitespaces)
                append("hostname = \(hosts)", to: "mitm")
            case "map local":
                let values = namedValues(in: line)
                guard let first = line.split(whereSeparator: \.isWhitespace).first else { continue }
                let pattern = String(first)
                let status = Int(values["status-code"] ?? "200") ?? 200
                var headers: [String: String] = [:]
                if let header = values["header"] {
                    for item in header.components(separatedBy: "|") {
                        guard let split = item.firstIndex(of: ":") else { throw unsupported(line) }
                        headers[String(item[..<split]).trimmingCharacters(in: .whitespaces)] = item[item.index(after: split)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                if values["data-type"] == "tiny-gif", status == 200, headers.isEmpty {
                    append("\(pattern) url reject-img", to: "rewrite_local")
                } else if let body = values["data"], values["data-type"] == "text" {
                    let result: [String: Any] = ["status": "HTTP/1.1 \(status)", "body": body, "headers": headers]
                    script(.inline("$done(\(try literal(result)));") , pattern: pattern, direction: "request", requiresBody: false)
                } else if let path = values["data-path"], let url = URL(string: path), ["http", "https"].contains(url.scheme?.lowercased()) {
                    script(.response(url, status: status, headers: headers), pattern: pattern, direction: "request", requiresBody: false)
                } else { throw unsupported(line) }
            case "header rewrite", "body rewrite":
                let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count == 3, ["http-request", "http-response"].contains(parts[0]) else { throw unsupported(line) }
                let direction = parts[0] == "http-request" ? "request" : "response"
                let request = direction == "request" ? "$request" : "$response"
                let body: String
                if section == "header rewrite" {
                    let values = words(in: parts[2])
                    guard let action = values.first else { throw unsupported(line) }
                    var statements: [String] = []
                    let arguments = Array(values.dropFirst())
                    switch action {
                    case "header-del":
                        guard !arguments.isEmpty else { throw unsupported(line) }
                        for key in arguments { statements.append("remove(\(try literal(key)));" ) }
                    case "header-add", "header-replace":
                        guard !arguments.isEmpty, arguments.count.isMultiple(of: 2) else { throw unsupported(line) }
                        for index in stride(from: 0, to: arguments.count, by: 2) {
                            statements.append("set(\(try literal(arguments[index])), \(try literal(arguments[index + 1])), \(action == "header-replace"));")
                        }
                    case "header-replace-regex":
                        guard !arguments.isEmpty, arguments.count.isMultiple(of: 3) else { throw unsupported(line) }
                        for index in stride(from: 0, to: arguments.count, by: 3) {
                            statements.append("replace(\(try literal(arguments[index])), \(try literal(arguments[index + 1])), \(try literal(arguments[index + 2])));")
                        }
                    default: throw unsupported(line)
                    }
                    body = """
                    const headers = Object.assign({}, \(request).headers);
                    const keyFor = name => Object.keys(headers).find(key => key.toLowerCase() === name.toLowerCase());
                    const remove = name => { const key = keyFor(name); if (key !== undefined) delete headers[key]; };
                    const set = (name, value, onlyExisting) => { const key = keyFor(name); if (!onlyExisting || key !== undefined) headers[key || name] = value; };
                    const replace = (name, pattern, value) => { const key = keyFor(name); if (key !== undefined) headers[key] = String(headers[key]).replace(new RegExp(pattern, 'g'), value); };
                    \(statements.joined(separator: "\n"))
                    $done({headers});
                    """
                } else {
                    let values = words(in: parts[2])
                    guard values.count == 2 else { throw unsupported(line) }
                    body = "$done({body: String(\(request).body).replace(new RegExp(\(try literal(values[0])), 'g'), \(try literal(values[1])))});"
                }
                script(.inline(body), pattern: parts[1], direction: direction, requiresBody: section == "body rewrite")
            case "general", "host", "proxy", "proxy group", "argument", "panel":
                throw unsupported(line)
            default:
                throw unsupported(line)
            }
        }
        return (order.map { "[\($0)]\n" + sections[$0, default: []].joined(separator: "\n") }.joined(separator: "\n\n") + "\n", scripts)
    }

    static func adaptingScript(_ original: String, argument: String?) throws -> String {
        """
        const relayDone = $done;
        (function($done) {
        const $argument = \(try literal(argument ?? ""));
        const $environment = {'surge-version': 'Script Hub'};
        const $persistentStore = {read: key => $prefs.valueForKey(key), write: (value, key) => $prefs.setValueForKey(value, key)};
        const $notification = {post: (title, subtitle, body, options) => $notify(title, subtitle, body, options)};
        const $httpClient = {};
        for (const method of ['get', 'post', 'put', 'delete', 'patch', 'head', 'options']) {
          $httpClient[method] = (value, callback) => {
            const request = typeof value === 'string' ? {url: value} : Object.assign({}, value);
            request.method = method.toUpperCase();
            $task.fetch(request).then(response => callback(null, {status: response.statusCode, statusCode: response.statusCode, headers: response.headers}, response.body), error => callback(String(error.error || error), null, null));
          };
        }
        \(original)
        })(value => {
          const result = value && value.response ? value.response : (value || {});
          if (typeof result.status === 'number') result.status = 'HTTP/1.1 ' + result.status;
          relayDone(result);
        });
        """
    }

    static func adaptingConvertedQuantumultXScript(_ converted: String) -> String {
        let signature = "(function relayQuantumultXHTTP(nativeHTTPClient) {"
        if converted.contains(signature) { return converted }
        return """
        (function($httpClient) {
        \(converted)
        })((function relayQuantumultXHTTP(nativeHTTPClient) {
          const client = {};
          for (const name of ['get', 'post', 'put', 'delete', 'patch', 'head', 'options']) {
            if (typeof nativeHTTPClient[name] !== 'function') continue;
            client[name] = (request, callback) => {
              const method = String(typeof request === 'object' && request.method || name).toLowerCase();
              if (typeof nativeHTTPClient[method] !== 'function') {
                callback('Unsupported HTTP method: ' + method.toUpperCase(), null, '');
                return;
              }
              nativeHTTPClient[method].call(nativeHTTPClient, request, (error, response, data) => {
                const reply = response ? Object.assign({}, response) : response;
                if (reply && reply.statusCode === undefined) reply.statusCode = reply.status;
                callback(error, reply, data);
              });
            };
          }
          return client;
        })($httpClient));
        """
    }

    static func responseScript(data: Data, status: Int, headers: [String: String]) throws -> String {
        guard let body = String(data: data, encoding: .utf8) else {
            throw RelayError.invalidOutput("Quantumult X 远程 Map Local 资源不是 UTF-8 文本。")
        }
        return "$done(\(try literal(["status": "HTTP/1.1 \(status)", "body": body, "headers": headers])));"
    }

    private static func literal(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed, .sortedKeys])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func namedValues(in line: String) -> [String: String] {
        let expression = try! NSRegularExpression(pattern: #"(?:^|(?<=[,\s]))([A-Za-z][A-Za-z0-9-]*)\s*=\s*"#)
        let candidates = expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
        let source = line as NSString
        var cursor = 0
        var quote: unichar?
        var escaped = false
        let matches = candidates.filter { match in
            while cursor < match.range.location {
                let character = source.character(at: cursor)
                if escaped { escaped = false }
                else if character == 92 { escaped = true }
                else if let current = quote { if character == current { quote = nil } }
                else if character == 34 || character == 39 { quote = character }
                cursor += 1
            }
            return quote == nil
        }
        var values: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            var value = source.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(",") { value.removeLast() }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                value = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) as? String)
                    ?? String(value.dropFirst().dropLast())
            }
            values[source.substring(with: match.range(at: 1)).lowercased()] = value
        }
        return values
    }

    private static func words(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #""([^"]*)"|'([^']*)'|(\S+)"#)
        let source = value as NSString
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
            for group in 1...3 where match.range(at: group).location != NSNotFound { return source.substring(with: match.range(at: group)) }
            return ""
        }
    }
}
