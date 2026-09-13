//  RuntimeLimitTests.swift
//  EBookExtensionRuntimeTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import EBookTestSupport
import Foundation
import Testing
@testable import EBookExtensionRuntime

struct RuntimeLimitTests {
    @Test func rejectsOversizedRequestWithoutDroppingBookmark() throws {
        var limits = EPUBLimits()
        limits.maxRequestBytes = 128
        let controller = EBookRuntimeController(limits: limits)
        defer { controller.shutdown() }
        let url = try makeEPUB()
        defer { try? FileManager.default.removeItem(at: url) }

        let request = RuntimeFixtures.request(
            for: url,
            bookmark: String(repeating: "A", count: 4096)
        )
        #expect(throws: RuntimeControllerError.self) {
            _ = try controller.createSession(request: request)
        }
    }

    @Test func fileEntryAndDirectoryLimitsBecomeLimitSessions() throws {
        let url = try makeEPUB()
        defer { try? FileManager.default.removeItem(at: url) }

        var fileLimits = EPUBLimits()
        fileLimits.maxFileBytes = 64
        try expectLimitSession(fileLimits, request: RuntimeFixtures.request(for: url))

        var entryLimits = EPUBLimits()
        entryLimits.maxEntryCount = 2
        try expectLimitSession(entryLimits, request: RuntimeFixtures.request(for: url))

        var directoryLimits = EPUBLimits()
        directoryLimits.maxCentralDirectoryBytes = 64
        try expectLimitSession(directoryLimits, request: RuntimeFixtures.request(for: url))
    }

    @Test func xmlDepthAndNodeLimitsFailChapterOnly() throws {
        let body = String(repeating: "<div>", count: 24) + "正文" + String(repeating: "</div>", count: 24)
        let url = try makeEPUB(chapters: [(id: "c1", title: "第一章", body: body)])
        defer { try? FileManager.default.removeItem(at: url) }

        var depthLimits = EPUBLimits()
        depthLimits.maxXMLDepth = 8
        try expectChapterLimit(depthLimits, request: RuntimeFixtures.request(for: url))

        var nodeLimits = EPUBLimits()
        nodeLimits.maxXMLNodeCount = 12
        try expectChapterLimit(nodeLimits, request: RuntimeFixtures.request(for: url))
    }

    @Test func chapterResourceAndHTMLBudgetsFailChapterOnly() throws {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: EPUBFixtureBuilder.containerXML)
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Budget</dc:title></metadata>
          <manifest>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="img" href="img.png" media-type="image/png"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """)
        builder.add(name: "OEBPS/c1.xhtml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>C1</title></head>
        <body><p>正文</p><img src="img.png" alt=""/></body></html>
        """)
        builder.add(name: "OEBPS/img.png", data: Data(repeating: 0xAB, count: 4096))
        let url = try RuntimeFixtures.writeEPUB(try builder.build())
        defer { try? FileManager.default.removeItem(at: url) }

        var resourceLimits = EPUBLimits()
        resourceLimits.maxChapterResourceBytes = 256
        try expectChapterLimit(resourceLimits, request: RuntimeFixtures.request(for: url))

        var htmlLimits = EPUBLimits()
        htmlLimits.maxChapterHTMLBytes = 64
        try expectChapterLimit(htmlLimits, request: RuntimeFixtures.request(for: url))
    }

    @Test func cachedHTMLBudgetKeepsExistingChapter() throws {
        let firstBody = String(repeating: "第一段 ", count: 200)
        let secondBody = String(repeating: "第二段 ", count: 200)
        let url = try makeEPUB(chapters: [
            (id: "c1", title: "一", body: firstBody),
            (id: "c2", title: "二", body: secondBody)
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let request = RuntimeFixtures.request(for: url)

        let generous = EBookRuntimeController()
        let firstSession = try generous.createSession(request: request)
        let firstURL = try #require(documentURL(firstSession))
        let firstSize = try FileManager.default.attributesOfItem(atPath: firstURL.path)[.size] as? Int
        let covered = try #require(firstSize)
        generous.shutdown()

        var limits = EPUBLimits()
        limits.maxCachedHTMLBytes = covered
        let controller = EBookRuntimeController(limits: limits)
        defer { controller.shutdown() }
        let created = try controller.createSession(request: request)
        #expect(RuntimeFixtures.presentationKind(created) == "document")
        let createdURL = try #require(documentURL(created))

        let activation = try navigateMessage(itemID: "spine:1", session: created)
        let failed = try controller.perform(navigation: activation, session: created)
        #expect(RuntimeFixtures.presentationMessageKey(failed) == "EBook Limit Exceeded")
        #expect(FileManager.default.fileExists(atPath: createdURL.path))
    }

    @Test func tocOverflowFallsBackToSpineAndSpineOverflowFails() throws {
        // 原始目录超限：降级为完整 spine 目录，正文仍可读。
        let navEntries = (0..<12).map { (title: "章节 \($0)", href: "c1.xhtml") }
        let navURL = try makeEPUB(
            chapters: [(id: "c1", title: "一", body: "x"), (id: "c2", title: "二", body: "y")],
            navEntries: navEntries
        )
        defer { try? FileManager.default.removeItem(at: navURL) }
        var tocLimits = EPUBLimits()
        tocLimits.maxNavigatorItems = 5
        let tocController = EBookRuntimeController(limits: tocLimits)
        defer { tocController.shutdown() }
        let fallback = try tocController.createSession(request: RuntimeFixtures.request(for: navURL))
        #expect(RuntimeFixtures.presentationKind(fallback) == "document")
        let fallbackIDs = RuntimeFixtures.navigatorItems(fallback).compactMap { $0["id"] as? String }
        #expect(!fallbackIDs.isEmpty)
        #expect(fallbackIDs.allSatisfy { $0.hasPrefix("spine:") })

        // spine 自身超限：创建限制错误会话。
        let chapters = (0..<6).map { (id: "c\($0)", title: "第\($0)章", body: "x") }
        let spineURL = try makeEPUB(chapters: chapters)
        defer { try? FileManager.default.removeItem(at: spineURL) }
        var spineLimits = EPUBLimits()
        spineLimits.maxNavigatorItems = 5
        let spineController = EBookRuntimeController(limits: spineLimits)
        defer { spineController.shutdown() }
        let session = try spineController.createSession(request: RuntimeFixtures.request(for: spineURL))
        #expect(RuntimeFixtures.presentationMessageKey(session) == "EBook Limit Exceeded")
        #expect(RuntimeFixtures.navigatorItems(session).isEmpty)
    }

    @Test func navigatorTitlesTruncateWithoutDroppingItems() throws {
        let url = try makeEPUB(
            chapters: [(id: "c1", title: "第一章", body: "x")],
            navEntries: [(title: "一个非常非常长的章节标题用于截断", href: "c1.xhtml")]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        var limits = EPUBLimits()
        limits.maxNavigatorTitleCharacters = 4
        let controller = EBookRuntimeController(limits: limits)
        defer { controller.shutdown() }
        let session = try controller.createSession(request: RuntimeFixtures.request(for: url))
        let items = RuntimeFixtures.navigatorItems(session)
        #expect(!items.isEmpty)
        for item in items {
            let title = item["title"] as? String ?? ""
            #expect(title.count <= 4)
        }
    }

    @Test func sessionBudgetFallsBackToSpineThenLimitSnapshot() throws {
        let longTitle = String(repeating: "超长标题", count: 200)
        let navEntries = (0..<400).map { _ in (title: longTitle, href: "c1.xhtml") }
        let url = try makeEPUB(
            chapters: [(id: "c1", title: "一", body: "x"), (id: "c2", title: "二", body: "y")],
            navEntries: navEntries
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let request = RuntimeFixtures.request(for: url)

        var measurementLimits = EPUBLimits()
        measurementLimits.maxSessionJSONBytes = 8 << 20
        let measurement = EBookRuntimeController(limits: measurementLimits)
        let fullSession = try measurement.createSession(request: request)
        let fullSize = try JSONSerialization.data(withJSONObject: fullSession).count
        #expect(RuntimeFixtures.navigatorItems(fullSession).contains { ($0["id"] as? String)?.hasPrefix("toc:") == true })
        measurement.shutdown()

        var fallbackLimits = EPUBLimits()
        fallbackLimits.maxSessionJSONBytes = fullSize / 2
        let fallback = EBookRuntimeController(limits: fallbackLimits)
        defer { fallback.shutdown() }
        let fallbackSession = try fallback.createSession(request: request)
        let fallbackIDs = RuntimeFixtures.navigatorItems(fallbackSession).compactMap { $0["id"] as? String }
        #expect(!fallbackIDs.isEmpty)
        #expect(fallbackIDs.allSatisfy { $0.hasPrefix("spine:") })

        var errorLimits = EPUBLimits()
        errorLimits.maxSessionJSONBytes = 16
        let errorController = EBookRuntimeController(limits: errorLimits)
        defer { errorController.shutdown() }
        let errorSession = try errorController.createSession(request: request)
        #expect(RuntimeFixtures.presentationMessageKey(errorSession) == "EBook Limit Exceeded")
        #expect(RuntimeFixtures.navigatorItems(errorSession).isEmpty)
    }

    // MARK: - Helpers

    private func makeEPUB(
        chapters: [(id: String, title: String, body: String)] = [(id: "c1", title: "一", body: "正文")],
        navEntries: [(title: String, href: String)] = []
    ) throws -> URL {
        try RuntimeFixtures.writeEPUB(
            try RuntimeFixtures.epub(chapters: chapters, navEntries: navEntries)
        )
    }

    private func expectLimitSession(_ limits: EPUBLimits, request: [String: Any]) throws {
        let controller = EBookRuntimeController(limits: limits)
        defer { controller.shutdown() }
        let session = try controller.createSession(request: request)
        #expect(RuntimeFixtures.presentationKind(session) == "unavailable")
        #expect(RuntimeFixtures.presentationMessageKey(session) == "EBook Limit Exceeded")
    }

    private func expectChapterLimit(_ limits: EPUBLimits, request: [String: Any]) throws {
        let controller = EBookRuntimeController(limits: limits)
        defer { controller.shutdown() }
        let session = try controller.createSession(request: request)
        #expect(RuntimeFixtures.presentationMessageKey(session) == "EBook Limit Exceeded")
        #expect(!RuntimeFixtures.navigatorItems(session).isEmpty)
    }

    private func documentURL(_ session: [String: Any]) -> URL? {
        guard let urlString = (session["presentation"] as? [String: Any])?["url"] as? String else { return nil }
        return URL(string: urlString)
    }

    private func navigateMessage(itemID: String, session: [String: Any]) throws -> NavigatorActionMessage {
        let object: [String: Any] = [
            "commandID": "ui.navigator.action",
            "contractVersion": 1,
            "action": [
                "contributionID": "ebook.toc",
                "kind": "activate",
                "itemIDs": [itemID]
            ],
            "session": session
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let message = try JSONDecoder().decode(NavigatorActionMessage.self, from: data)
        try message.validate()
        return message
    }
}
