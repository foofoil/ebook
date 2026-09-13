//  EPUBSpacingTests.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import EBookTestSupport
import Foundation
import WebKit
import Testing

@MainActor
@Suite(.serialized)
struct EPUBSpacingTests {
    /// 书籍用 class + !important 设大边距/pre-wrap 时，阅读排版仍须生效。
    @Test func readerStylesOverrideBookImportantMargins() async throws {
        let url = try TestFile.write(try bookWithAggressiveStyles())
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try EPUBDocument(url: url)
        let html = try document.renderChapter(at: 0)
        let webView = try await loadInWebView(html: html)

        let marginTop = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('p.para')).marginTop"
        ) as? String
        let marginBottom = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('p.para')).marginBottom"
        ) as? String
        let whiteSpace = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('p.para')).whiteSpace"
        ) as? String

        #expect(marginTop == "4px", "marginTop=\(marginTop ?? "nil")")
        #expect(marginBottom == "4px", "marginBottom=\(marginBottom ?? "nil")")
        #expect(whiteSpace == "normal", "whiteSpace=\(whiteSpace ?? "nil")")
    }

    private func bookWithAggressiveStyles() throws -> Data {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: EPUBFixtureBuilder.containerXML)
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>间距书</dc:title></metadata>
          <manifest>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """)
        builder.add(name: "OEBPS/c1.xhtml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>间距</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
          <body><p class="para">第一段</p><p class="para">第二段</p></body>
        </html>
        """)
        builder.add(name: "OEBPS/style.css", text: """
        p.para { margin: 3em 0 !important; white-space: pre-wrap !important; line-height: 1.2 !important; }
        """)
        return try builder.build()
    }

    private func loadInWebView(html: String) async throws -> WKWebView {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-spacing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("chapter.html")
        try Data(html.utf8).write(to: fileURL)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        let waiter = SpacingNavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL)
        await waiter.waitForFinish()
        return webView
    }
}

@MainActor
private final class SpacingNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForFinish() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume()
        continuation = nil
    }
}
