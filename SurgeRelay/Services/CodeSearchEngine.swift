import Foundation

/// 文本编辑器的查找条件。
struct CodeSearchQuery: Equatable, Sendable {
    var text: String
    var isCaseSensitive: Bool
    var usesRegularExpression: Bool

    init(text: String, isCaseSensitive: Bool = false, usesRegularExpression: Bool = false) {
        self.text = text
        self.isCaseSensitive = isCaseSensitive
        self.usesRegularExpression = usesRegularExpression
    }

    var isEmpty: Bool { text.isEmpty }
}

/// 模块文本查找与替换的纯逻辑。
///
/// 全部按 UTF-16 偏移工作，与 `NSTextView` 的选区一致，因此含中文、Emoji 的
/// 模块内容也能正确定位。
enum CodeSearchEngine {
    /// 单次查找允许的匹配数量上限，避免超大文档在每次输入时构造巨大数组。
    static let maximumMatchCount = 5_000

    static func matches(in text: String, query: CodeSearchQuery) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let string = text as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        guard fullRange.length > 0 else { return [] }

        if query.usesRegularExpression {
            guard let expression = regularExpression(for: query) else { return [] }
            var results: [NSRange] = []
            expression.enumerateMatches(in: text, range: fullRange) { match, _, stop in
                guard let match, match.range.length > 0 else { return }
                results.append(match.range)
                if results.count >= maximumMatchCount { stop.pointee = true }
            }
            return results
        }

        var options: NSString.CompareOptions = [.literal]
        if !query.isCaseSensitive { options.insert(.caseInsensitive) }
        var results: [NSRange] = []
        var searchRange = fullRange
        while searchRange.length > 0 {
            let found = string.range(of: query.text, options: options, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            results.append(found)
            if results.count >= maximumMatchCount { break }
            let nextLocation = NSMaxRange(found)
            searchRange = NSRange(location: nextLocation, length: string.length - nextLocation)
        }
        return results
    }

    /// 与 `selection` 完全一致的匹配下标，用于把“当前匹配”标记同步到选区。
    static func matchIndex(in matches: [NSRange], equalTo selection: NSRange) -> Int? {
        matches.firstIndex { NSEqualRanges($0, selection) }
    }

    /// 从当前选区出发的下一个/上一个匹配下标，到头后回绕。
    static func adjacentMatchIndex(
        in matches: [NSRange],
        from selection: NSRange,
        forward: Bool
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        if forward {
            let start = NSMaxRange(selection)
            return matches.firstIndex { $0.location >= start } ?? 0
        }
        let end = selection.location
        return matches.lastIndex { NSMaxRange($0) <= end } ?? matches.count - 1
    }

    /// 单个匹配的替换文本。正则模式支持 `$1` 之类的捕获组模板。
    static func replacement(
        for match: NSRange,
        in text: String,
        query: CodeSearchQuery,
        template: String
    ) -> String {
        guard query.usesRegularExpression,
              let expression = regularExpression(for: query),
              // .anchored 保证取到的就是 match 起点上的那一次匹配，
              // 而不是范围内的其他匹配。
              let result = expression.firstMatch(in: text, options: [.anchored], range: match) else {
            return template
        }
        return expression.replacementString(for: result, in: text, offset: 0, template: template)
    }

    /// 一次替换全部匹配，返回新文本与替换次数。
    static func replacingAll(
        in text: String,
        query: CodeSearchQuery,
        template: String
    ) -> (text: String, count: Int) {
        guard !query.isEmpty else { return (text, 0) }
        let string = text as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        if query.usesRegularExpression {
            guard let expression = regularExpression(for: query) else { return (text, 0) }
            let count = expression.numberOfMatches(in: text, range: fullRange)
            guard count > 0 else { return (text, 0) }
            return (
                expression.stringByReplacingMatches(
                    in: text,
                    range: fullRange,
                    withTemplate: template
                ),
                count
            )
        }
        let found = matches(in: text, query: query)
        guard !found.isEmpty else { return (text, 0) }
        let result = NSMutableString(string: string)
        // 从后往前替换，前面的匹配偏移不会被改动影响。
        for match in found.reversed() {
            result.replaceCharacters(in: match, with: template)
        }
        return (result as String, found.count)
    }

    static func matchSummary(matchCount: Int, currentNumber: Int?) -> String {
        guard matchCount > 0 else { return "无结果" }
        guard let currentNumber else { return "\(matchCount) 个结果" }
        return "第 \(currentNumber) / \(matchCount) 个"
    }

    static func regularExpressionErrorMessage(for query: CodeSearchQuery) -> String? {
        guard query.usesRegularExpression, !query.isEmpty else { return nil }
        return regularExpression(for: query) == nil ? "正则表达式无效" : nil
    }

    private static func regularExpression(for query: CodeSearchQuery) -> NSRegularExpression? {
        var options: NSRegularExpression.Options = []
        if !query.isCaseSensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: query.text, options: options)
    }
}
