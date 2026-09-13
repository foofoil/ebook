//  EPUBTableOfContents.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

public struct EPUBTOCEntry: Sendable, Equatable {
    public let id: String
    public let title: String
    public let path: String?
    public let fragment: String?
    public let children: [EPUBTOCEntry]
}

/// EPUB3 nav 优先、EPUB2 NCX 回退；两者都不可用时返回空数组，由调用方用 spine 目录兜底。
enum EPUBTableOfContentsBuilder {
    static func build(package: EPUBPackage, archive: ZIPArchive, limits: EPUBLimits) throws -> [EPUBTOCEntry] {
        if let nav = package.navItem(), archive.contains(nav.path),
           let entries = try navEntries(navPath: nav.path, archive: archive, limits: limits),
           !entries.isEmpty {
            return entries
        }
        if let ncx = ncxItem(package: package), archive.contains(ncx.path),
           let entries = try ncxEntries(ncxPath: ncx.path, archive: archive, limits: limits),
           !entries.isEmpty {
            return entries
        }
        return []
    }

    private static func ncxItem(package: EPUBPackage) -> EPUBManifestItem? {
        if let id = package.ncxItemID, let item = package.manifest[id] { return item }
        return package.manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }
    }

    // MARK: - EPUB3 nav

    private static func navEntries(
        navPath: String,
        archive: ZIPArchive,
        limits: EPUBLimits
    ) throws -> [EPUBTOCEntry]? {
        let data = try archive.data(for: navPath, maxBytes: 8 << 20)
        let document = try EPUBXML.parse(data, limits: limits, failure: .invalidPackage)
        let navs = document.rootElement()?.descendants(localName: "nav") ?? []
        guard let nav = navs.first(where: { $0.attributeValue(localName: "type") == "toc" }) ?? navs.first else {
            return nil
        }
        guard let list = nav.descendants(localName: "ol").first else { return nil }
        var budget = Budget(limits: limits)
        return try parseList(list, baseDirectory: EPUBPath.directory(of: navPath), budget: &budget, idPrefix: "toc:")
    }

    private static func parseList(
        _ list: XMLElement,
        baseDirectory: String,
        budget: inout Budget,
        idPrefix: String
    ) throws -> [EPUBTOCEntry] {
        var entries: [EPUBTOCEntry] = []
        for (index, item) in list.elements(forLocalName: "li").enumerated() {
            try budget.begin(depth: idPrefix.split(separator: ".").count)
            let anchor = item.elements(forLocalName: "a").first
            let span = item.elements(forLocalName: "span").first
            let rawTitle = (anchor ?? span)?.trimmedText ?? ""
            let resolved = anchor?.attributeValue(localName: "href")
                .flatMap { EPUBPath.resolve(reference: $0, relativeTo: baseDirectory) }
            let title = rawTitle.isEmpty
                ? (resolved?.path.split(separator: "/").last.map(String.init) ?? "")
                : rawTitle
            let id = "\(idPrefix)\(index)"
            let childList = item.elements(forLocalName: "ol").first
            let children = try childList.map {
                try parseList($0, baseDirectory: baseDirectory, budget: &budget, idPrefix: "\(id).")
            } ?? []
            guard !title.isEmpty else { continue }
            budget.consumeTitle(title)
            entries.append(EPUBTOCEntry(
                id: id,
                title: title,
                path: resolved?.path,
                fragment: resolved?.fragment,
                children: children
            ))
        }
        return entries
    }

    // MARK: - EPUB2 NCX

    private static func ncxEntries(
        ncxPath: String,
        archive: ZIPArchive,
        limits: EPUBLimits
    ) throws -> [EPUBTOCEntry]? {
        let data = try archive.data(for: ncxPath, maxBytes: 8 << 20)
        let document = try EPUBXML.parse(data, limits: limits, failure: .invalidPackage)
        guard let navMap = document.rootElement()?.descendants(localName: "navMap").first else { return nil }
        var budget = Budget(limits: limits)
        return try parseNavPoints(
            navMap,
            baseDirectory: EPUBPath.directory(of: ncxPath),
            budget: &budget,
            idPrefix: "toc:"
        )
    }

    private static func parseNavPoints(
        _ parent: XMLElement,
        baseDirectory: String,
        budget: inout Budget,
        idPrefix: String
    ) throws -> [EPUBTOCEntry] {
        var entries: [EPUBTOCEntry] = []
        for (index, point) in parent.elements(forLocalName: "navPoint").enumerated() {
            try budget.begin(depth: idPrefix.split(separator: ".").count)
            let title = point.descendants(localName: "text").first?.trimmedText ?? ""
            let src = point.elements(forLocalName: "content").first?.attributeValue(localName: "src")
            let resolved = src.flatMap { EPUBPath.resolve(reference: $0, relativeTo: baseDirectory) }
            let id = "\(idPrefix)\(index)"
            let children = try parseNavPoints(
                point,
                baseDirectory: baseDirectory,
                budget: &budget,
                idPrefix: "\(id)."
            )
            guard !title.isEmpty else { continue }
            budget.consumeTitle(title)
            entries.append(EPUBTOCEntry(
                id: id,
                title: title,
                path: resolved?.path,
                fragment: resolved?.fragment,
                children: children
            ))
        }
        return entries
    }

    private struct Budget {
        let limits: EPUBLimits
        private var nodes = 0

        init(limits: EPUBLimits) {
            self.limits = limits
        }

        mutating func begin(depth: Int) throws {
            nodes += 1
            guard nodes <= limits.maxNavigatorItems else { throw EPUBError.limitExceeded }
            guard depth <= limits.maxNavigatorDepth else { throw EPUBError.limitExceeded }
        }

        mutating func consumeTitle(_ title: String) {
            _ = title.prefix(limits.maxNavigatorTitleCharacters)
        }
    }
}
