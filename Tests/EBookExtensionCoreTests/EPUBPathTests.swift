//  EPUBPathTests.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import Foundation
import Testing

struct EPUBPathTests {
    @Test func resolvesRelativeReferencesWithFragment() {
        let reference = EPUBPath.resolve(reference: "../images/pic.png#frag", relativeTo: "OEBPS/text")
        #expect(reference?.path == "OEBPS/images/pic.png")
        #expect(reference?.fragment == "frag")
    }

    @Test func rejectsEscapesSchemesQueriesAndBackslashes() {
        #expect(EPUBPath.resolve(reference: "../../../etc/passwd", relativeTo: "OEBPS") == nil)
        #expect(EPUBPath.resolve(reference: "http://example.com/a.png", relativeTo: "OEBPS") == nil)
        #expect(EPUBPath.resolve(reference: "//example.com/a.png", relativeTo: "OEBPS") == nil)
        #expect(EPUBPath.resolve(reference: "a.png?query=1", relativeTo: "OEBPS") == nil)
        #expect(EPUBPath.resolve(reference: "..\\windows.png", relativeTo: "OEBPS") == nil)
        #expect(EPUBPath.resolve(reference: "%2E%2E%2F..%2Fescape.png", relativeTo: "OEBPS") == nil)
    }

    @Test func decodesPercentOnce() {
        let reference = EPUBPath.resolve(reference: "%E7%AC%AC%E4%B8%80%E7%AB%A0.xhtml", relativeTo: "OEBPS")
        #expect(reference?.path == "OEBPS/第一章.xhtml")
        #expect(EPUBPath.resolve(reference: "%ZZ.xhtml", relativeTo: "OEBPS") == nil)
    }

    @Test func stripsFragmentForFileIdentity() {
        let url = URL(string: "file:///tmp/book.html#note-1")!
        #expect(EPUBPath.fileIdentity(of: url) == "/tmp/book.html")
    }
}
