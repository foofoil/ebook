//  EPUBCoverTests.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import EBookTestSupport
import Foundation
import Testing

struct EPUBCoverTests {
    @Test func findsEPUB3CoverImageProperty() throws {
        try assertCoverFound(style: "epub3")
    }

    @Test func findsEPUB2MetaCover() throws {
        try assertCoverFound(style: "epub2")
    }

    @Test func findsGuideCoverThroughXHTML() throws {
        try assertCoverFound(style: "guide")
    }

    @Test func returnsNilWhenNoImageExists() throws {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: EPUBFixtureBuilder.containerXML)
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
          <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """)
        builder.add(name: "OEBPS/c1.xhtml", text: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>x</p></body></html>")
        let url = try TestFile.write(try builder.build())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try EPUBDocument(url: url).coverImage() == nil)
    }

    private func assertCoverFound(style: String) throws {
        let url = try TestFile.write(EPUBFixtureBuilder.coverEPUB(style: style))
        defer { try? FileManager.default.removeItem(at: url) }
        let cover = try EPUBDocument(url: url).coverImage()
        #expect(cover != nil, "style=\(style)")
        #expect(cover?.pathExtension == "png")
        #expect(cover?.data == EPUBFixtureBuilder.pixelPNG)
    }
}
