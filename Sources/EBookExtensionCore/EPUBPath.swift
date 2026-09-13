//  EPUBPath.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// 包内引用解析：拆 fragment、拒绝 query 与外部 scheme，百分号只解码一次，
/// 允许合法 `../`，但拒绝越过包根。
public enum EPUBPath {
    public struct Reference: Equatable, Sendable {
        public let path: String
        public let fragment: String?
    }

    public static func resolve(reference: String, relativeTo baseDirectory: String) -> Reference? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        guard !rawPath.contains("?"), !trimmed.contains("\0") else { return nil }

        if rawPath.isEmpty {
            // 纯 fragment：指向引用文件自身，由调用方决定归属。
            guard let fragment, !fragment.isEmpty else { return nil }
            return Reference(path: "", fragment: fragment)
        }
        guard !rawPath.hasPrefix("//"),
              rawPath.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) == nil,
              let decoded = rawPath.removingPercentEncoding else { return nil }

        var stack = baseDirectory.split(separator: "/").map(String.init)
        for component in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default:
                guard !component.contains("\\") else { return nil }
                stack.append(String(component))
            }
        }
        guard !stack.isEmpty else { return nil }
        return Reference(path: stack.joined(separator: "/"), fragment: fragment)
    }

    /// 文档所在目录，用于相对引用基准。
    public static func directory(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex ..< index])
    }

    /// 去掉 fragment 的规范化文件身份。
    public static func fileIdentity(of url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.standardizedFileURL.path ?? url.standardizedFileURL.path
    }
}
