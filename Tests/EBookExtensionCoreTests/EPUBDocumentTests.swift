//  EPUBDocumentTests.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import EBookTestSupport
import Foundation
import Testing

struct EPUBDocumentTests {
    @Test func parsesEPUB3MetadataChaptersAndNavigation() throws {
        let url = try TestFile.write(EPUBFixtureBuilder.minimalEPUB3())
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try EPUBDocument(url: url)
        #expect(document.title == "测试书")
        #expect(document.creators == ["测试作者"])
        #expect(document.language == "zh")
        #expect(document.chapters.count == 2)
        #expect(document.chapters[0].title == "第一章")
        #expect(document.chapters[1].title == "第二章")
        #expect(document.firstLinearChapterIndex == 0)

        #expect(document.toc.count == 2)
        #expect(document.toc[0].children.count == 2)
        #expect(document.toc[0].children[0].id == "toc:0.0")
        #expect(document.toc[0].children[1].fragment == "s2")
        #expect(document.toc[1].path == "OEBPS/chapter2.xhtml")
    }

    @Test func parsesEPUB2NCXAndLinearFlag() throws {
        let url = try TestFile.write(EPUBFixtureBuilder.minimalEPUB2())
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try EPUBDocument(url: url)
        #expect(document.chapters.count == 2)
        #expect(document.chapters[1].linear == false)
        #expect(document.toc.count == 2)
        #expect(document.toc[0].title == "第一章")
        #expect(document.toc[0].children.first?.fragment == "s1")
    }

    @Test func rendersSelfContainedChapter() throws {
        let url = try TestFile.write(EPUBFixtureBuilder.minimalEPUB3())
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try EPUBDocument(url: url)
        let html = try document.renderChapter(at: 0)
        #expect(html.contains("第一章"))
        #expect(html.contains("正文内容"))
        #expect(html.contains("data:image/png;base64,"))
        #expect(html.contains("Content-Security-Policy"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("alert("))
        #expect(!html.contains("href=\"chapter2.xhtml\""))
        #expect(html.contains("href=\"#s1\""))
        #expect(html.contains("color: #333333"))
        #expect(html.contains("background-image: url(\"data:image/png;base64,"))
    }

    @Test func rejectsUnknownEntityAndBrokenArchive() throws {
        let unknown = try TestFile.write(
            EPUBFixtureBuilder.minimalEPUB3(extraChapterBody: "<p>&bogus;</p>")
        )
        defer { try? FileManager.default.removeItem(at: unknown) }
        let document = try EPUBDocument(url: unknown)
        #expect(throws: EPUBError.chapterRenderingFailed) {
            _ = try document.renderChapter(at: 0)
        }

        let brokenURL = try TestFile.write(Data(repeating: 0x7A, count: 512))
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        #expect(throws: EPUBError.invalidArchive) {
            _ = try EPUBDocument(url: brokenURL)
        }
    }

    @Test func rejectsUnsupportedSpineMediaType() throws {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: EPUBFixtureBuilder.containerXML)
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
          <manifest>
            <item id="img" href="cover.jpg" media-type="image/jpeg"/>
          </manifest>
          <spine><itemref idref="img"/></spine>
        </package>
        """)
        builder.add(name: "OEBPS/cover.jpg", data: Data([0xFF, 0xD8]))
        let url = try TestFile.write(try builder.build())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: EPUBError.unsupportedContent) {
            _ = try EPUBDocument(url: url)
        }
    }
}
