//  CSSResourceRewriterTests.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

@testable import EBookExtensionCore
import Foundation
import Testing

struct CSSResourceRewriterTests {
    @Test func removesImportsAndRewritesURLs() {
        let css = """
        @import url("other.css");
        /* url(keep-comment.css) */
        p { background: url('images/a.png'); color: red; }
        div { background-image: url(images/b.png); }
        """
        let rewritten = CSSResourceRewriter.rewrite(css) { reference in
            reference.hasSuffix(".png") ? "data:image/png;base64,AAAA" : nil
        }
        #expect(!rewritten.contains("@import"))
        #expect(rewritten.contains("url(\"data:image/png;base64,AAAA\")"))
        #expect(rewritten.contains("/* url(keep-comment.css) */"))
        #expect(!rewritten.contains("images/a.png"))
        #expect(!rewritten.contains("images/b.png"))
    }

    @Test func dropsRemoteAndDataReferences() {
        let css = "p { background: url(https://example.com/a.png); }"
        let rewritten = CSSResourceRewriter.rewrite(css) { _ in "unused" }
        #expect(rewritten.contains("none"))
        #expect(!rewritten.contains("https://"))
    }
}
