//  EPUBDocument.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// EPUB 门面：打开后暴露元数据、spine 章节与目录，按需渲染单章自包含 HTML。
public final class EPUBDocument {
    public struct Chapter: Sendable, Equatable {
        public let index: Int
        public let path: String
        public let title: String
        public let linear: Bool
    }

    public let url: URL
    public let title: String?
    public let creators: [String]
    public let language: String?
    public let chapters: [Chapter]
    public let toc: [EPUBTOCEntry]
    public let limits: EPUBLimits
    public let firstLinearChapterIndex: Int

    private let archive: ZIPArchive
    private let renderer: EPUBChapterRenderer

    public init(url: URL, limits: EPUBLimits = .default) throws {
        self.url = url
        self.limits = limits
        let archive = try ZIPArchive(url: url, limits: limits)
        let opfPath = try EPUBContainer.rootfilePath(in: archive, limits: limits)
        let package = try EPUBPackage.parse(archive: archive, opfPath: opfPath, limits: limits)
        // 目录错误或超限不阻塞正文：降级为空目录，由 Runtime 用 spine 分组兜底。
        let toc = (try? EPUBTableOfContentsBuilder.build(
            package: package,
            archive: archive,
            limits: limits
        )) ?? []
        let tocTitles = Self.firstTOCPathTitles(toc, limits: limits)
        var chapters: [Chapter] = []
        chapters.reserveCapacity(package.spine.count)
        for (index, item) in package.spine.enumerated() {
            let filename = item.path.split(separator: "/").last.map(String.init) ?? item.path
            let title = tocTitles[item.path]
                ?? package.manifest[item.manifestID]?.id
                ?? filename
            chapters.append(Chapter(index: index, path: item.path, title: title, linear: item.linear))
        }
        self.chapters = chapters
        self.toc = toc
        self.title = package.title
        self.creators = package.creators
        self.language = package.language
        self.firstLinearChapterIndex = package.spine.firstIndex(where: \.linear) ?? 0
        self.archive = archive
        self.renderer = EPUBChapterRenderer(
            archive: archive,
            limits: limits,
            obfuscatedFontPaths: package.obfuscatedFontPaths
        )
    }

    public func renderChapter(at index: Int) throws -> String {
        guard chapters.indices.contains(index) else { throw EPUBError.invalidPackage }
        let chapter = chapters[index]
        let data = try archive.data(for: chapter.path)
        return try renderer.render(chapterPath: chapter.path, data: data)
    }

    /// spine 起始索引；用于目录项 → 章节映射。
    public func firstSpineIndex(forPath path: String) -> Int? {
        chapters.firstIndex { $0.path == path }
    }

    private static func firstTOCPathTitles(_ entries: [EPUBTOCEntry], limits: EPUBLimits) -> [String: String] {
        var result: [String: String] = [:]
        var stack = entries
        while let entry = stack.first {
            stack.removeFirst()
            if let path = entry.path, result[path] == nil {
                result[path] = String(entry.title.prefix(limits.maxNavigatorTitleCharacters))
            }
            stack.insert(contentsOf: entry.children, at: 0)
        }
        return result
    }
}
