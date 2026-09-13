//  CSSDarkModeTransformer.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// 为深色外观生成书籍 CSS 的前景色覆盖：把在深色背景上不可读的暗色提亮。
/// 浅色背景的规则（代码卡片、高亮块）保持不变，避免深色文字配浅色底被改坏。
enum CSSDarkModeTransformer {
    static func darkModeCSS(for css: String) -> String {
        let characters = Array(css)
        var result = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                var cursor = index + 2
                while cursor + 1 < characters.count,
                      !(characters[cursor] == "*" && characters[cursor + 1] == "/") {
                    cursor += 1
                }
                index = min(characters.count, cursor + 2)
                continue
            }
            if character == "@" {
                index = skipAtRule(characters, from: index)
                continue
            }

            var brace = index
            while brace < characters.count, characters[brace] != "{" { brace += 1 }
            guard brace < characters.count else { break }
            let selector = String(characters[index ..< brace]).trimmingCharacters(in: .whitespacesAndNewlines)

            var end = brace + 1
            var depth = 1
            while end < characters.count, depth > 0 {
                if characters[end] == "{" { depth += 1 }
                if characters[end] == "}" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            let declarations = String(characters[(brace + 1) ..< min(end, characters.count)])
            if let adjusted = adjustedDeclarations(declarations), !selector.isEmpty {
                result += selector + "{" + adjusted + "}\n"
            }
            index = min(characters.count, end + 1)
        }
        return result
    }

    private static func skipAtRule(_ characters: [Character], from start: Int) -> Int {
        var cursor = start
        while cursor < characters.count, characters[cursor] != ";", characters[cursor] != "{" { cursor += 1 }
        guard cursor < characters.count, characters[cursor] == "{" else {
            return min(characters.count, cursor + 1)
        }
        var depth = 0
        while cursor < characters.count {
            if characters[cursor] == "{" { depth += 1 }
            if characters[cursor] == "}" {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return cursor
    }

    /// 返回调整后的声明；没有任何颜色需要调整时返回 nil，避免放大深色样式。
    private static func adjustedDeclarations(_ declarations: String) -> String? {
        let pieces = declarations.split(separator: ";", omittingEmptySubsequences: false)
        var changed = false
        var output: [String] = []

        for piece in pieces {
            let declaration = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !declaration.isEmpty else { continue }
            guard let colon = declaration.firstIndex(of: ":") else {
                output.append(declaration)
                continue
            }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(declaration[declaration.index(after: colon)...])
            switch property {
            case "color":
                if let adjusted = lightenedColorDeclaration(value) {
                    output.append("color: \(adjusted)")
                    changed = true
                } else {
                    output.append(declaration)
                }
            case "background", "background-color":
                // 浅色提示块/代码块背景在深色下压暗，避免"浅底浅字"。
                if let adjusted = darkenedBackgroundDeclaration(value) {
                    output.append("\(property): \(adjusted)")
                    changed = true
                } else {
                    output.append(declaration)
                }
            default:
                output.append(declaration)
            }
        }
        return changed ? output.joined(separator: "; ") : nil
    }

    private static func darkenedBackgroundDeclaration(_ value: String) -> String? {
        guard let match = firstColorMatch(in: value), let color = parseColor(match.token) else { return nil }
        guard color.alpha > 0, luminance(color) > 0.6 else { return nil }
        return "#" + hex(darken(color)) + match.suffix
    }

    private static func lightenedColorDeclaration(_ value: String) -> String? {
        guard let match = firstColorMatch(in: value), let color = parseColor(match.token) else { return nil }
        guard color.alpha > 0, luminance(color) < 0.45 else { return nil }
        let lightened = lighten(color, targetLuminance: 0.62)
        return "#" + hex(lightened) + match.suffix
    }

    // MARK: - 颜色解析

    private struct Color {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    private struct ColorMatch {
        let token: String
        let suffix: String
    }

    private static func firstColorMatch(in value: String) -> ColorMatch? {
        let pattern = #"^\s*(#[0-9a-fA-F]{3,8}|rgba?\([^)]*\))(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = value as NSString
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: text.length)) else {
            return nil
        }
        return ColorMatch(
            token: text.substring(with: match.range(at: 1)),
            suffix: text.substring(with: match.range(at: 2))
        )
    }

    private static func parseColor(_ token: String) -> Color? {
        let lower = token.lowercased()
        if lower.hasPrefix("#") {
            var hexDigits = String(lower.dropFirst())
            if hexDigits.count == 3 || hexDigits.count == 4 {
                hexDigits = hexDigits.map { "\($0)\($0)" }.joined()
            }
            guard hexDigits.count == 6 || hexDigits.count == 8,
                  let value = UInt64(hexDigits, radix: 16) else { return nil }
            let hasAlpha = hexDigits.count == 8
            return Color(
                red: Double((value >> (hasAlpha ? 24 : 16)) & 0xFF),
                green: Double((value >> (hasAlpha ? 16 : 8)) & 0xFF),
                blue: Double((value >> (hasAlpha ? 8 : 0)) & 0xFF),
                alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
            )
        }
        guard lower.hasPrefix("rgb") else { return nil }
        guard let open = lower.firstIndex(of: "("), let close = lower.firstIndex(of: ")") else { return nil }
        let components = lower[lower.index(after: open) ..< close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count >= 3,
              let red = Double(components[0]),
              let green = Double(components[1]),
              let blue = Double(components[2]) else { return nil }
        let alpha = components.count >= 4 ? (Double(components[3]) ?? 1) : 1
        return Color(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func luminance(_ color: Color) -> Double {
        linearLuminance(red: color.red, green: color.green, blue: color.blue)
    }

    private static func linearLuminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * toLinear(red) + 0.7152 * toLinear(green) + 0.0722 * toLinear(blue)
    }

    private static func toLinear(_ channel: Double) -> Double {
        let value = channel / 255
        return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func toSRGB(_ linear: Double) -> Double {
        let value = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return value * 255
    }

    /// 在线性空间里向白色混合，精确达到目标相对亮度，保证深色背景上的对比度。
    private static func lighten(_ color: Color, targetLuminance: Double) -> Color {
        let current = luminance(color)
        guard current < targetLuminance, current < 1 else { return color }
        let factor = min(1, max(0, (targetLuminance - current) / (1 - current)))
        func blend(_ channel: Double) -> Double {
            toSRGB(toLinear(channel) + (1 - toLinear(channel)) * factor)
        }
        return Color(red: blend(color.red), green: blend(color.green), blue: blend(color.blue), alpha: color.alpha)
    }

    /// 在线性空间里整体压暗浅色背景，保留原有色相。
    private static func darken(_ color: Color) -> Color {
        func scale(_ channel: Double) -> Double { toSRGB(toLinear(channel) * 0.06) }
        return Color(red: scale(color.red), green: scale(color.green), blue: scale(color.blue), alpha: color.alpha)
    }

    private static func hex(_ color: Color) -> String {
        func clamp(_ value: Double) -> Int { min(255, max(0, Int(value.rounded()))) }
        return String(format: "%02x%02x%02x", clamp(color.red), clamp(color.green), clamp(color.blue))
    }
}
