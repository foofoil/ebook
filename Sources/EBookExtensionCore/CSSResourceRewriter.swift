//  CSSResourceRewriter.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// CSS 资源重写：移除 `@import`，把 `url(...)` 交给解析闭包重写。
/// 手写扫描器识别注释、引号与反斜杠转义，不用单个正则承担安全校验。
enum CSSResourceRewriter {
    static func rewrite(_ css: String, resolve: (String) throws -> String?) rethrows -> String {
        let characters = Array(css)
        var output = String()
        output.reserveCapacity(css.count)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                let end = findCommentEnd(characters, from: index + 2) ?? characters.count
                output.append(contentsOf: characters[index ..< end])
                index = end
                continue
            }

            if character == "@", matchesImport(characters, at: index) {
                index = skipImport(characters, from: index)
                continue
            }

            if matchesURL(characters, at: index) {
                let (replacement, nextIndex) = try parseURL(characters, from: index, resolve: resolve)
                output.append(replacement)
                index = nextIndex
                continue
            }

            output.append(character)
            index += 1
        }
        return output
    }

    private static func findCommentEnd(_ characters: [Character], from start: Int) -> Int? {
        var index = start
        while index + 1 < characters.count {
            if characters[index] == "*", characters[index + 1] == "/" { return index + 2 }
            index += 1
        }
        return nil
    }

    private static func matchesImport(_ characters: [Character], at index: Int) -> Bool {
        let keyword = Array("@import")
        guard index + keyword.count <= characters.count else { return false }
        for offset in 0 ..< keyword.count where
            String(characters[index + offset]).lowercased() != String(keyword[offset]) {
            return false
        }
        // 关键字后必须是空白或引号/url，避免 @importx。
        let next = index + keyword.count
        guard next >= characters.count
                || characters[next].isWhitespace
                || characters[next] == "\""
                || characters[next] == "'"
                || characters[next] == "u"
                || characters[next] == "U" else { return false }
        return true
    }

    /// 跳过整条 @import 规则（到 `;`；畸形时到块结束或字符串结尾）。
    private static func skipImport(_ characters: [Character], from start: Int) -> Int {
        var index = start
        var quote: Character?
        var depth = 0
        while index < characters.count {
            let character = characters[index]
            if let currentQuote = quote {
                if character == "\\" { index += 2; continue }
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if character == ";", depth == 0 {
                return index + 1
            }
            index += 1
        }
        return index
    }

    private static func matchesURL(_ characters: [Character], at index: Int) -> Bool {
        guard index + 4 <= characters.count else { return false }
        let token = String(characters[index ..< index + 4]).lowercased()
        guard token == "url(" else { return false }
        // 前缀不能是标识符字符，避免匹配到 no-url(。
        if index > 0 {
            let previous = characters[index - 1]
            if previous.isLetter || previous.isNumber || previous == "-" || previous == "_" {
                return false
            }
        }
        return true
    }

    private static func parseURL(
        _ characters: [Character],
        from start: Int,
        resolve: (String) throws -> String?
    ) rethrows -> (String, Int) {
        var index = start + 4
        var inner = ""
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            if let currentQuote = quote {
                if character == "\\", index + 1 < characters.count {
                    inner.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == currentQuote {
                    quote = nil
                    index += 1
                    continue
                }
                inner.append(character)
            } else if character == "\"" || character == "'" {
                guard inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ("url()", index + 1)
                }
                quote = character
            } else if character == ")" {
                let reference = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reference.isEmpty else { return ("none", index + 1) }
                if reference.hasPrefix("data:") || reference.hasPrefix("#")
                    || reference.lowercased().hasPrefix("http:")
                    || reference.lowercased().hasPrefix("https:")
                    || reference.hasPrefix("//") {
                    return ("none", index + 1)
                }
                guard let replacement = try resolve(reference) else { return ("none", index + 1) }
                return ("url(\"\(replacement)\")", index + 1)
            } else {
                inner.append(character)
            }
            index += 1
        }
        return ("none", index)
    }
}
