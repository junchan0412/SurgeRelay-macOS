import Foundation

/// 一次可撤销的文本替换：替换范围、替换内容和替换后的选区。
struct CodeEditorEdit: Equatable, Sendable {
    var range: NSRange
    var replacement: String
    var selection: NSRange
}

/// 代码编辑器的纯文本变换：缩进、注释、保持缩进换行和按行定位。
///
/// 变换结果统一表达为一次范围替换，`ModuleCodeTextView` 只需把它交给
/// `NSTextView.shouldChangeText(in:replacementString:)`，撤销、重做和
/// 输入法状态就由 AppKit 统一维护。
enum CodeEditorTextTransform {
    static let indentUnit = "    "
    static let commentMarker = "#"

    static func indent(in text: String, selection: NSRange, unit: String = indentUnit) -> CodeEditorEdit {
        let string = text as NSString
        guard selection.length > 0 else {
            return CodeEditorEdit(
                range: selection,
                replacement: unit,
                selection: NSRange(location: selection.location + (unit as NSString).length, length: 0)
            )
        }
        let lineRange = string.lineRange(for: selection)
        let replacement = lines(of: string.substring(with: lineRange))
            .map { $0.isEmpty ? $0 : unit + $0 }
            .joined(separator: "\n")
        return CodeEditorEdit(
            range: lineRange,
            replacement: replacement,
            selection: NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
    }

    static func unindent(in text: String, selection: NSRange, unit: String = indentUnit) -> CodeEditorEdit? {
        let string = text as NSString
        let lineRange = string.lineRange(for: selection)
        let original = string.substring(with: lineRange)
        let replacement = lines(of: original)
            .map { line -> String in
                if line.hasPrefix(unit) { return String(line.dropFirst(unit.count)) }
                if line.hasPrefix("\t") || line.hasPrefix(" ") { return String(line.dropFirst()) }
                return line
            }
            .joined(separator: "\n")
        guard replacement != original else { return nil }
        return CodeEditorEdit(
            range: lineRange,
            replacement: replacement,
            selection: NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
    }

    static func newlineKeepingIndentation(in text: String, selection: NSRange) -> CodeEditorEdit {
        let string = text as NSString
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let prefix = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let indentation = String(prefix.prefix(while: { $0 == " " || $0 == "\t" }))
        let replacement = "\n" + indentation
        return CodeEditorEdit(
            range: selection,
            replacement: replacement,
            selection: NSRange(
                location: selection.location + (replacement as NSString).length,
                length: 0
            )
        )
    }

    /// 切换选中行的注释。全部非空行已注释时取消注释，否则按最小缩进列添加注释。
    static func toggleComment(
        in text: String,
        selection: NSRange,
        marker: String = commentMarker
    ) -> CodeEditorEdit? {
        let string = text as NSString
        guard string.length > 0 else { return nil }
        let lineRange = string.lineRange(for: selection)
        let original = string.substring(with: lineRange)
        let originalLines = lines(of: original)
        let contentLines = originalLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !contentLines.isEmpty else { return nil }

        let isCommented = contentLines.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
        }
        let updatedLines: [String]
        if isCommented {
            updatedLines = originalLines.map { line in
                guard let markerIndex = line.range(of: marker) else { return line }
                var remainder = line[markerIndex.upperBound...]
                if remainder.hasPrefix(" ") { remainder = remainder.dropFirst() }
                return String(line[line.startIndex..<markerIndex.lowerBound]) + remainder
            }
        } else {
            let indentation = contentLines
                .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
                .min() ?? 0
            updatedLines = originalLines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let index = line.index(line.startIndex, offsetBy: min(indentation, line.count))
                return String(line[line.startIndex..<index]) + "\(marker) " + String(line[index...])
            }
        }
        let replacement = updatedLines.joined(separator: "\n")
        guard replacement != original else { return nil }

        let selectionAfterEdit: NSRange
        if selection.length > 0 {
            selectionAfterEdit = NSRange(
                location: lineRange.location,
                length: (replacement as NSString).length
            )
        } else {
            // 光标状态下保持在同一行的相同相对位置，按该行长度变化平移。
            let firstLineDelta = (updatedLines.first?.count ?? 0) - (originalLines.first?.count ?? 0)
            let offsetInRange = selection.location - lineRange.location
            let shifted = max(0, min(offsetInRange + firstLineDelta, (replacement as NSString).length))
            selectionAfterEdit = NSRange(location: lineRange.location + shifted, length: 0)
        }
        return CodeEditorEdit(
            range: lineRange,
            replacement: replacement,
            selection: selectionAfterEdit
        )
    }

    static func lineCount(in text: String) -> Int {
        let string = text as NSString
        guard string.length > 0 else { return 1 }
        return lineStarts(in: string).count
    }

    /// 1 起算的行号对应的字符范围（不含换行符）；行号越界时返回 nil。
    static func range(in text: String, forLine line: Int) -> NSRange? {
        let string = text as NSString
        guard line >= 1 else { return nil }
        guard string.length > 0 else { return line == 1 ? NSRange(location: 0, length: 0) : nil }
        let starts = lineStarts(in: string)
        guard line <= starts.count else { return nil }
        let start = starts[line - 1]
        let fullLineRange = string.lineRange(for: NSRange(location: start, length: 0))
        return NSRange(location: start, length: contentLength(of: fullLineRange, in: string))
    }

    /// 行范围去掉尾部换行符后的长度。
    ///
    /// 按 UTF-16 单元判断而不是 Swift `Character`：`\r\n` 在 Swift 里是单个
    /// grapheme cluster，用字符比较无法识别，会把换行算进行内容。
    private static func contentLength(of lineRange: NSRange, in string: NSString) -> Int {
        var length = lineRange.length
        while length > 0 {
            let unit = string.character(at: lineRange.location + length - 1)
            guard unit == 0x0A || unit == 0x0D || unit == 0x0085 || unit == 0x2028 || unit == 0x2029 else {
                break
            }
            length -= 1
        }
        return length
    }

    private static func lineStarts(in string: NSString) -> [Int] {
        var starts = [0]
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let newline = string.range(of: "\n", options: [], range: searchRange)
            guard newline.location != NSNotFound else { break }
            let nextStart = NSMaxRange(newline)
            guard nextStart < string.length else { break }
            starts.append(nextStart)
            searchRange = NSRange(location: nextStart, length: string.length - nextStart)
        }
        return starts
    }

    private static func lines(of value: String) -> [String] {
        value.components(separatedBy: "\n")
    }
}
