//  RuntimeFixtures.swift
//  EBookExtensionRuntimeTests
//
//  Created by 董超 on 2026/9/13.
//

import Foundation
import EBookTestSupport

enum RuntimeFixtures {
    static func writeEPUB(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("epub")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func request(for url: URL, bookmark: String? = nil) -> [String: Any] {
        var resource: [String: Any] = ["url": url.absoluteString]
        if let bookmark { resource["securityScopedBookmark"] = bookmark }
        return ["kind": "singleFile", "resource": resource]
    }

    /// 仅含 spine 的最小 EPUB，可选 EPUB3 nav。
    static func epub(
        chapters: [(id: String, title: String, body: String)],
        navEntries: [(title: String, href: String)] = [],
        extraEntries: [(String, Data)] = [],
        metadataTitle: String = "Limits"
    ) throws -> Data {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: EPUBFixtureBuilder.containerXML)
        let manifestItems = chapters.map {
            "<item id=\"\($0.id)\" href=\"\($0.id).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spineItems = chapters.map { "<itemref idref=\"\($0.id)\"/>" }.joined(separator: "\n")
        let navItem = navEntries.isEmpty
            ? ""
            : "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(metadataTitle)</dc:title>
          </metadata>
          <manifest>\(manifestItems)\(navItem)</manifest>
          <spine>\(spineItems)</spine>
        </package>
        """)
        for chapter in chapters {
            builder.add(name: "OEBPS/\(chapter.id).xhtml", text: """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>\(chapter.title)</title></head>
              <body><h1>\(chapter.title)</h1><p>\(chapter.body)</p></body>
            </html>
            """)
        }
        if !navEntries.isEmpty {
            let items = navEntries.map { "<li><a href=\"\($0.href)\">\($0.title)</a></li>" }.joined(separator: "\n")
            builder.add(name: "OEBPS/nav.xhtml", text: """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <head><title>Nav</title></head>
              <body><nav epub:type="toc"><ol>\(items)</ol></nav></body>
            </html>
            """)
        }
        for (name, data) in extraEntries {
            builder.add(name: name, data: data)
        }
        return try builder.build()
    }

    static func presentationKind(_ session: [String: Any]) -> String {
        (session["presentation"] as? [String: Any])?["kind"] as? String ?? ""
    }

    static func presentationMessageKey(_ session: [String: Any]) -> String {
        (session["presentation"] as? [String: Any])?["messageKey"] as? String ?? ""
    }

    static func navigatorItems(_ session: [String: Any]) -> [[String: Any]] {
        guard let contributions = session["navigatorContributions"] as? [[String: Any]],
              let items = contributions.first?["items"] as? [[String: Any]] else { return [] }
        return items
    }

    static func navigatorSelectedItemIDs(_ session: [String: Any]) -> [String] {
        guard let contributions = session["navigatorContributions"] as? [[String: Any]],
              let selected = contributions.first?["selectedItemIDs"] as? [String] else { return [] }
        return selected
    }
}
