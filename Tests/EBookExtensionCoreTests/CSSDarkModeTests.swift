//  CSSDarkModeTests.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookTestSupport
import Foundation
import WebKit
import Testing

@testable import EBookExtensionCore

@MainActor
@Suite(.serialized)
struct CSSDarkModeTests {
    @Test func darkModeLightensDarkForegroundColors() {
        let css = """
        .k { color: #000088; }
        .s { color: rgb(204, 51, 0); }
        .hll { background-color: #ffffcc; color: #000000; }
        .ok { color: #eeeeee; }
        """
        let dark = CSSDarkModeTransformer.darkModeCSS(for: css)
        #expect(dark.contains(".k{"))
        #expect(!dark.contains(".hll"))   // 浅色背景的代码卡片保持不变
        #expect(!dark.contains(".ok"))    // 本就够亮的颜色不动

        let darkColor = colorHex(in: dark, selector: ".k")
        #expect(darkColor != nil)
        #expect(luminance(hex: darkColor!) > 0.45, "dark=\(darkColor ?? "nil")")
    }

    @Test func renderedChapterCarriesDarkOverrides() throws {
        let html = try renderCodeChapter()
        #expect(html.contains("@media (prefers-color-scheme: dark)"))
        let darkBlock = html.components(separatedBy: "@media (prefers-color-scheme: dark)").last ?? ""
        #expect(darkBlock.contains(".k{color: #"))
        #expect(!darkBlock.contains("#000088"))
    }

    /// 深色外观下，代码 token 使用提亮后的颜色。
    @Test func darkAppearanceUsesLightenedCodeColor() async throws {
        let html = try renderCodeChapter()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        defer { window.orderOut(nil) }

        let waiter = DarkModeNavigationWaiter()
        webView.navigationDelegate = waiter
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-dark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("chapter.html")
        try Data(html.utf8).write(to: fileURL)
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL)
        await waiter.waitForFinish()

        let color = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.k')).color"
        ) as? String
        #expect(color != nil)
        #expect(color != "rgb(0, 0, 136)", "color=\(color ?? "nil")")
    }

    // MARK: - Helpers

    private func renderCodeChapter() throws -> String {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: EPUBFixtureBuilder.containerXML)
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>代码书</dc:title></metadata>
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
          <head><title>代码</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
          <body><pre><code class="k">fn main()</code></pre></body>
        </html>
        """)
        builder.add(name: "OEBPS/style.css", text: ".k { color: #000088; }")
        let url = try TestFile.write(try builder.build())
        defer { try? FileManager.default.removeItem(at: url) }
        return try EPUBDocument(url: url).renderChapter(at: 0)
    }

    private func colorHex(in css: String, selector: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: selector) + #"\{color:\s*#([0-9a-fA-F]{6})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)),
              let range = Range(match.range(at: 1), in: css) else { return nil }
        return String(css[range])
    }

    private func luminance(hex: String) -> Double {
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return 0 }
        func linear(_ channel: Double) -> Double {
            let v = channel / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(Double((value >> 16) & 0xFF))
            + 0.7152 * linear(Double((value >> 8) & 0xFF))
            + 0.0722 * linear(Double(value & 0xFF))
    }
}

@MainActor
private final class DarkModeNavigationWaiter: NSObject, WKNavigationDelegate {
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
