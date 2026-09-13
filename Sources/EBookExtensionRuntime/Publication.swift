//  Publication.swift
//  EBookExtensionRuntime
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import Foundation

/// 会话内不可变的目录投影：原始目录节点 + 覆盖全部 spine 正文的“全部章节”分组。
struct Publication: Sendable {
    struct Node: Sendable {
        let id: String
        let title: String
        let parentID: String?
        let chapterIndex: Int?
        let fragment: String?
        let isEnabled: Bool
    }

    let nodes: [Node]

    static func make(document: EPUBDocument, limits: EPUBLimits) throws -> Publication {
        var nodes: [Node] = []
        var count = 0

        func append(_ entries: [EPUBTOCEntry], parentID: String?) throws {
            for entry in entries {
                count += 1
                guard count <= limits.maxNavigatorItems else { throw EPUBError.limitExceeded }
                let chapterIndex = entry.path.flatMap { document.firstSpineIndex(forPath: $0) }
                nodes.append(Node(
                    id: entry.id,
                    title: truncated(entry.title, limits: limits),
                    parentID: parentID,
                    chapterIndex: chapterIndex,
                    fragment: entry.fragment,
                    isEnabled: chapterIndex != nil
                ))
                try append(entry.children, parentID: entry.id)
            }
        }

        try append(document.toc, parentID: nil)
        // spine 分组自身也占一个节点。
        guard count + document.chapters.count + 1 <= limits.maxNavigatorItems else {
            throw EPUBError.limitExceeded
        }
        nodes.append(Node(
            id: "spine:root",
            title: allChaptersTitle,
            parentID: nil,
            chapterIndex: nil,
            fragment: nil,
            isEnabled: false
        ))
        for chapter in document.chapters {
            nodes.append(Node(
                id: "spine:\(chapter.index)",
                title: truncated(chapter.title, limits: limits),
                parentID: "spine:root",
                chapterIndex: chapter.index,
                fragment: nil,
                isEnabled: true
            ))
        }
        return Publication(nodes: nodes)
    }

    func node(id: String) -> Node? {
        nodes.first { $0.id == id }
    }

    static var allChaptersTitle: String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return language.hasPrefix("zh") ? "全部章节" : "All Chapters"
    }

    private static func truncated(_ title: String, limits: EPUBLimits) -> String {
        String(title.prefix(limits.maxNavigatorTitleCharacters))
    }
}
