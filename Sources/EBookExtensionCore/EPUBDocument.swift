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

    public struct CoverImage: Sendable {
        public let data: Data
        public let pathExtension: String
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
    private let coverPath: String?

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
        self.coverPath = Self.resolveCoverPath(package: package, archive: archive, limits: limits)
        self.renderer = EPUBChapterRenderer(
            archive: archive,
            limits: limits,
            obfuscatedFontPaths: package.obfuscatedFontPaths
        )
    }

    /// 封面图数据；无封面时为 nil。宿主可用它生成历史缩略图。
    public func coverImage() -> CoverImage? {
        guard let coverPath,
              let data = try? archive.data(for: coverPath, maxBytes: limits.maxChapterResourceBytes),
              !data.isEmpty else { return nil }
        let ext = (coverPath as NSString).pathExtension.lowercased()
        return CoverImage(data: data, pathExtension: ext.isEmpty ? "jpg" : ext)
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

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "tif", "tiff"]

    /// 解析封面：EPUB3 cover-image 属性 → EPUB2 meta cover → guide → 文件名启发 → 首个图片。
    private static func resolveCoverPath(package: EPUBPackage, archive: ZIPArchive, limits: EPUBLimits) -> String? {
        func isImagePath(_ path: String) -> Bool {
            imageExtensions.contains((path as NSString).pathExtension.lowercased())
        }
        func usable(_ path: String) -> Bool {
            archive.contains(path) && isImagePath(path)
        }

        if let item = package.manifest.values.first(where: { $0.properties.contains("cover-image") }), usable(item.path) {
            return item.path
        }
        if let id = package.coverImageItemID, let item = package.manifest[id], usable(item.path) {
            return item.path
        }
        if let guide = package.guideCoverPath, archive.contains(guide) {
            if isImagePath(guide) { return guide }
            if let inner = firstImagePath(inDocument: guide, archive: archive, limits: limits) { return inner }
        }
        if let item = package.manifest.values.first(where: { item in
            usable(item.path)
                && (item.id.lowercased().contains("cover")
                    || (item.path as NSString).lastPathComponent.lowercased().contains("cover"))
        }) {
            return item.path
        }
        return package.manifest.values
            .filter { $0.mediaType.hasPrefix("image/") || isImagePath($0.path) }
            .sorted { $0.path < $1.path }
            .first(where: { archive.contains($0.path) })?
            .path
    }

    private static func firstImagePath(inDocument path: String, archive: ZIPArchive, limits: EPUBLimits) -> String? {
        guard let data = try? archive.data(for: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let prepared = (try? HTMLEntities.preprocess(text)) ?? text
        guard let preparedData = prepared.data(using: .utf8),
              let document = try? EPUBXML.parse(preparedData, limits: limits, failure: .chapterRenderingFailed),
              let root = document.rootElement() else { return nil }
        let baseDirectory = EPUBPath.directory(of: path)
        for element in root.descendants(localName: "img") + root.descendants(localName: "image") {
            guard let src = element.attributeValue(localName: "src")
                ?? element.attributeValue(localName: "href"),
                let resolved = EPUBPath.resolve(reference: src, relativeTo: baseDirectory),
                archive.contains(resolved.path),
                imageExtensions.contains((resolved.path as NSString).pathExtension.lowercased()) else { continue }
            return resolved.path
        }
        return nil
    }

    private static func firstTOCPathTitles(_ entries: [EPUBTOCEntry], limits: EPUBLimits) -> [String: String] {        var result: [String: String] = [:]
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
