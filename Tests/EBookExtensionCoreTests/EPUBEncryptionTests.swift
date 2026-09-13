//  EPUBEncryptionTests.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import EBookTestSupport
import Foundation
import Testing

struct EPUBEncryptionTests {
    @Test func idpfFontObfuscationDegradesToSystemFonts() throws {
        try assertFontObfuscationDegrades(algorithm: "http://www.idpf.org/2008/embedding")
    }

    @Test func adobeFontObfuscationDegradesToSystemFonts() throws {
        try assertFontObfuscationDegrades(algorithm: "http://ns.adobe.com/pdf/enc#RC")
    }

    @Test func unknownEncryptionAndNonFontTargetsAreRejected() throws {
        let unknown = try TestFile.write(EPUBFixtureBuilder.obfuscatedFontEPUB(
            algorithm: "http://example.com/unknown"
        ))
        defer { try? FileManager.default.removeItem(at: unknown) }
        #expect(throws: EPUBError.encrypted) {
            _ = try EPUBDocument(url: unknown)
        }

        let nonFont = try TestFile.write(EPUBFixtureBuilder.obfuscatedFontEPUB(
            target: "OEBPS/c1.xhtml"
        ))
        defer { try? FileManager.default.removeItem(at: nonFont) }
        #expect(throws: EPUBError.encrypted) {
            _ = try EPUBDocument(url: nonFont)
        }
    }

    @Test func malformedEncryptionFileIsInvalidPackage() throws {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: EPUBFixtureBuilder.containerXML)
        builder.add(name: "META-INF/encryption.xml", text: "<encryption><broken>")
        builder.add(name: "OEBPS/content.opf", text: EPUBFixtureBuilder.epub3OPF(title: "T", creator: "A"))
        builder.add(name: "OEBPS/nav.xhtml", text: EPUBFixtureBuilder.epub3Nav)
        builder.add(name: "OEBPS/chapter1.xhtml", text: EPUBFixtureBuilder.chapterOne(extra: ""))
        let url = try TestFile.write(try builder.build())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: EPUBError.invalidPackage) {
            _ = try EPUBDocument(url: url)
        }
    }

    private func assertFontObfuscationDegrades(algorithm: String) throws {
        let url = try TestFile.write(EPUBFixtureBuilder.obfuscatedFontEPUB(algorithm: algorithm))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try EPUBDocument(url: url)
        let html = try document.renderChapter(at: 0)
        #expect(html.contains("字体混淆仍可阅读。"))
        #expect(!html.contains("data:font/"))
        #expect(html.contains("none"))
    }
}
