import Foundation

struct SourceProbe {

    enum Language {
        case swift
        case gdscript
        case gdshader
    }

    let raw: String
    let code: String
    let codeWithoutStrings: String
    let joinedFromMultipleFiles: Bool

    init(_ source: String, language: Language, joinedFromMultipleFiles: Bool = false) {
        raw = source
        self.joinedFromMultipleFiles = joinedFromMultipleFiles
        (code, codeWithoutStrings) = Self.strip(source, language: language)
    }

    func contains(_ needle: String) -> Bool { code.contains(needle) }

    func count(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var remainder = code[...]
        while let range = remainder.firstRange(of: needle) {
            count += 1
            remainder = remainder[range.upperBound...]
        }
        return count
    }

    func count(ofIdentifier name: String) -> Int {
        guard !name.isEmpty else { return 0 }
        func isIdentChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }
        var count = 0
        var searchStart = code.startIndex
        while let range = code.range(of: name, range: searchStart..<code.endIndex) {
            let boundedLeft = range.lowerBound == code.startIndex
                || !isIdentChar(code[code.index(before: range.lowerBound)])
            let boundedRight = range.upperBound == code.endIndex
                || !isIdentChar(code[range.upperBound])
            if boundedLeft && boundedRight { count += 1 }
            searchStart = range.upperBound
        }
        return count
    }

    func captures(pattern: String) throws -> [String] {
        try refuseOrderQueryOnJoinedSource()
        return try matches(pattern: pattern).map { String(code[$0[0]]) }
    }

    func integers(pattern: String) throws -> [Int] {
        try captures(pattern: pattern).compactMap(Int.init)
    }

    func pairs(pattern: String) throws -> [(String, String)] {
        try refuseOrderQueryOnJoinedSource()
        return try matches(pattern: pattern).map { (String(code[$0[0]]), String(code[$0[1]])) }
    }

    struct OrderQueryOnJoinedSource: Error, CustomStringConvertible {
        let description = "Reihenfolge-Abfrage auf einer aus mehreren Dateien "
            + "gefügten Probe — die Treffer-Reihenfolge wäre alphabetischer "
            + "Sortier-Zufall. Die eine Datei direkt proben."
    }

    private func refuseOrderQueryOnJoinedSource() throws {
        if joinedFromMultipleFiles { throw OrderQueryOnJoinedSource() }
    }

    var codeLinesWithoutStrings: [String] {
        codeWithoutStrings.components(separatedBy: "\n")
    }

    func swiftMethods() -> [(name: String, body: String)] {
        var result: [(String, String)] = []
        var current: String?
        var body = ""
        for line in codeWithoutStrings.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = Self.methodName(line) {
                if let open = current { result.append((open, body)) }
                current = name
                body = ""
            }
            if current != nil { body += line + "\n" }
        }
        if let open = current { result.append((open, body)) }
        return result
    }

    func testMethods() -> [(name: String, body: String)] {
        swiftMethods().filter { $0.name.hasPrefix("test") }
    }

    private static func methodName(_ line: Substring) -> String? {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return nil }
        let tokens = line.dropFirst(4).split(separator: " ")
        guard let keyword = tokens.firstIndex(of: "func"), keyword + 1 < tokens.count,
              tokens[..<keyword].allSatisfy({
                  $0.hasPrefix("@") || declarationModifiers.contains(String($0))
              })
        else { return nil }
        let signature = tokens[keyword + 1]
        return String(signature[signature.startIndex..<(signature.firstIndex(of: "(")
                                                        ?? signature.endIndex)])
    }

    private static let declarationModifiers: Set<String> = [
        "public", "private", "internal", "fileprivate", "open", "package",
        "static", "class", "final", "override", "mutating", "nonmutating",
        "nonisolated", "convenience", "required", "dynamic", "distributed",
        "consuming", "borrowing", "isolated",
    ]

    private func matches(pattern: String) throws -> [[Range<String.Index>]] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap { match in
            var groups: [Range<String.Index>] = []
            for i in 1..<match.numberOfRanges {
                guard let group = Range(match.range(at: i), in: code) else { return nil }
                groups.append(group)
            }
            return groups.isEmpty ? nil : groups
        }
    }

    private static func strip(_ source: String, language: Language)
        -> (code: String, codeWithoutStrings: String) {
        let chars = Array(source)
        var code = "", sansStrings = ""
        var i = 0

        func at(_ text: String) -> Bool {
            i + text.count <= chars.count
                && String(chars[i..<i + text.count]) == text
        }
        func emit(_ c: Character) { code.append(c); sansStrings.append(c) }

        func delimiterIsEscaped() -> Bool {
            var backslashes = 0
            var cursor = i
            while cursor > 0, chars[cursor - 1] == "\\" {
                backslashes += 1
                cursor -= 1
            }
            return backslashes % 2 == 1
        }

        func stringDelimiter() -> (open: String, close: String)? {
            let forms: [String]
            switch language {
            case .swift: forms = ["\"\"\"", "\""]
            case .gdscript: forms = ["\"\"\"", "'''", "\"", "'"]
            case .gdshader: return nil
            }
            for form in forms where at(form) { return (form, form) }
            return nil
        }

        let lineComment = language == .gdscript ? "#" : "//"
        let blockComments = language != .gdscript

        while i < chars.count {
            if at(lineComment) {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if blockComments, at("/*") {
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if at("/*") { depth += 1; i += 2 }
                    else if at("*/") { depth -= 1; i += 2 }
                    else {
                        if chars[i] == "\n" { emit("\n") }
                        i += 1
                    }
                }
            } else if let (open, close) = stringDelimiter() {
                code += open
                i += open.count
                let multiline = open.count == 3
                while i < chars.count {
                    if at(close), !delimiterIsEscaped() {
                        code += close
                        i += close.count
                        break
                    } else if chars[i] == "\n", !multiline {
                        break
                    } else {
                        if chars[i] == "\n" { sansStrings.append("\n") }
                        code.append(chars[i])
                        i += 1
                    }
                }
            } else {
                emit(chars[i])
                i += 1
            }
        }
        return (code, sansStrings)
    }
}
