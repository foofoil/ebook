//  RuntimeSessionTests.swift
//  EBookExtensionRuntimeTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import EBookTestSupport
import Foundation
import Testing
@testable import EBookExtensionRuntime

struct RuntimeSessionTests {
    @Test func obfuscatedFontBookCreatesDocumentSession() throws {
        let url = try RuntimeFixtures.writeEPUB(EPUBFixtureBuilder.obfuscatedFontEPUB())
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = EBookRuntimeController()
        defer { controller.shutdown() }

        let session = try controller.createSession(request: RuntimeFixtures.request(for: url))
        #expect(RuntimeFixtures.presentationKind(session) == "document")
        #expect(!RuntimeFixtures.navigatorItems(session).isEmpty)
    }

    /// 有封面时会话带 thumbnailURL，指向会话临时目录内可读的封面文件。
    @Test func sessionExposesCoverThumbnail() throws {
        let url = try RuntimeFixtures.writeEPUB(EPUBFixtureBuilder.coverEPUB())
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = EBookRuntimeController()
        defer { controller.shutdown() }

        let session = try controller.createSession(request: RuntimeFixtures.request(for: url))
        let thumbnail = try #require((session["thumbnailURL"] as? String).flatMap(URL.init(string:)))
        #expect(thumbnail.isFileURL)
        #expect(FileManager.default.fileExists(atPath: thumbnail.path))
        #expect(!(try Data(contentsOf: thumbnail)).isEmpty)
    }

    @Test func errorSessionsMapStableKeys() throws {
        let controller = EBookRuntimeController()
        defer { controller.shutdown() }

        let encryptedURL = try RuntimeFixtures.writeEPUB(EPUBFixtureBuilder.obfuscatedFontEPUB(
            algorithm: "http://example.com/unknown"
        ))
        defer { try? FileManager.default.removeItem(at: encryptedURL) }
        let encrypted = try controller.createSession(request: RuntimeFixtures.request(for: encryptedURL))
        #expect(RuntimeFixtures.presentationMessageKey(encrypted) == "EBook Encrypted Unsupported")

        let brokenURL = try RuntimeFixtures.writeEPUB(Data(repeating: 0x5A, count: 256))
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        let broken = try controller.createSession(request: RuntimeFixtures.request(for: brokenURL))
        #expect(RuntimeFixtures.presentationMessageKey(broken) == "EBook Invalid EPUB")

        let imageURL = try RuntimeFixtures.writeEPUB(try imageSpineEPUB())
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let image = try controller.createSession(request: RuntimeFixtures.request(for: imageURL))
        #expect(RuntimeFixtures.presentationMessageKey(image) == "EBook Unsupported Content")
    }

    @Test func rejectsUnsupportedResourceRequests() throws {
        let url = try RuntimeFixtures.writeEPUB(EPUBFixtureBuilder.minimalEPUB3())
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = EBookRuntimeController()
        defer { controller.shutdown() }

        let twoFiles: [String: Any] = [
            "kind": "fileCollection",
            "resources": [["url": url.absoluteString], ["url": url.absoluteString]]
        ]
        #expect(throws: RuntimeControllerError.self) {
            _ = try controller.createSession(request: twoFiles)
        }

        let textURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("text".utf8).write(to: textURL)
        defer { try? FileManager.default.removeItem(at: textURL) }
        #expect(throws: RuntimeControllerError.self) {
            _ = try controller.createSession(request: RuntimeFixtures.request(for: textURL))
        }

        #expect(throws: RuntimeControllerError.self) {
            _ = try controller.createSession(request: [
                "kind": "restoredSession",
                "extensionID": "app.foofoil.extension.ebook",
                "stateReference": "x"
            ])
        }
    }

    @Test func restoreReturnsSameSessionAndCloseIsIdempotent() throws {
        let url = try RuntimeFixtures.writeEPUB(EPUBFixtureBuilder.minimalEPUB3())
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = EBookRuntimeController()
        defer { controller.shutdown() }

        let created = try controller.createSession(request: RuntimeFixtures.request(for: url))
        let createdURL = try #require(documentURL(created))
        let createdID = try #require(created["id"] as? String)

        let restore = try lifecycleMessage(operation: "restore", session: created, restoration: [:])
        let restored = try controller.perform(lifecycle: restore, session: created)
        #expect(restored["id"] as? String == createdID)
        #expect(documentURL(restored) == createdURL)

        let close = try lifecycleMessage(operation: "close", session: created)
        let closed = try controller.perform(lifecycle: close, session: created)
        #expect(RuntimeFixtures.presentationMessageKey(closed) == "EBook Session Closed")

        let repeated = try controller.perform(lifecycle: close, session: closed)
        #expect(RuntimeFixtures.presentationMessageKey(repeated) == "EBook Session Closed")

        let navigation = try navigateMessage(itemID: "spine:0", session: closed)
        #expect(throws: RuntimeControllerError.self) {
            _ = try controller.perform(navigation: navigation, session: closed)
        }
        let restoreAfterClose = try lifecycleMessage(operation: "restore", session: closed, restoration: [:])
        #expect(throws: RuntimeControllerError.self) {
            _ = try controller.perform(lifecycle: restoreAfterClose, session: closed)
        }
    }

    /// 恢复携带旧目录选中项时跳到对应章节；无效项保持当前位置，不建新会话。
    @Test func restoreJumpsToSavedReadingPosition() throws {
        let url = try RuntimeFixtures.writeEPUB(EPUBFixtureBuilder.minimalEPUB3())
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = EBookRuntimeController()
        defer { controller.shutdown() }

        // 旧会话翻到第二章后关闭，模拟宿主保存的目录选中项。
        let previous = try controller.createSession(request: RuntimeFixtures.request(for: url))
        _ = try controller.perform(
            navigation: navigateMessage(itemID: "spine:1", session: previous),
            session: previous
        )
        let close = try lifecycleMessage(operation: "close", session: previous)
        _ = try controller.perform(lifecycle: close, session: previous)

        // 历史重开从首章开始；restore 带旧选中项应回到第二章。
        let fresh = try controller.createSession(request: RuntimeFixtures.request(for: url))
        #expect(documentURL(fresh)?.lastPathComponent == "chapter-0000.html")
        let restore = try lifecycleMessage(
            operation: "restore",
            session: fresh,
            restoration: ["currentItemID": "spine:1"]
        )
        let restored = try controller.perform(lifecycle: restore, session: fresh)
        #expect(restored["id"] as? String == fresh["id"] as? String)
        #expect(documentURL(restored)?.lastPathComponent == "chapter-0001.html")
        #expect(RuntimeFixtures.navigatorSelectedItemIDs(restored) == ["spine:1"])

        // 无效目录项：保持当前位置，会话不受影响。
        let bogus = try lifecycleMessage(
            operation: "restore",
            session: restored,
            restoration: ["currentItemID": "spine:99"]
        )
        let unchanged = try controller.perform(lifecycle: bogus, session: restored)
        #expect(documentURL(unchanged)?.lastPathComponent == "chapter-0001.html")
        #expect(RuntimeFixtures.navigatorSelectedItemIDs(unchanged) == ["spine:1"])
    }

    // MARK: - Helpers

    private func imageSpineEPUB() throws -> Data {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: EPUBFixtureBuilder.containerXML)
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
          <manifest><item id="img" href="cover.jpg" media-type="image/jpeg"/></manifest>
          <spine><itemref idref="img"/></spine>
        </package>
        """)
        builder.add(name: "OEBPS/cover.jpg", data: Data([0xFF, 0xD8, 0xFF]))
        return try builder.build()
    }

    private func documentURL(_ session: [String: Any]) -> URL? {
        guard let urlString = (session["presentation"] as? [String: Any])?["url"] as? String else { return nil }
        return URL(string: urlString)
    }

    private func lifecycleMessage(
        operation: String,
        session: [String: Any],
        restoration: [String: Any]? = nil
    ) throws -> SessionLifecycleMessage {
        var object: [String: Any] = [
            "commandID": "session.lifecycle",
            "contractVersion": 1,
            "operation": operation,
            "session": session
        ]
        if let restoration { object["restoration"] = restoration }
        let data = try JSONSerialization.data(withJSONObject: object)
        let message = try JSONDecoder().decode(SessionLifecycleMessage.self, from: data)
        try message.validate()
        return message
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
