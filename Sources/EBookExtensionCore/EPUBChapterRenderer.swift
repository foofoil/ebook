//  EPUBChapterRenderer.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// 把一章 XHTML 清理并组装为自包含 HTML：移除脚本与外部引用，包内图片/字体内联为 data URI。
struct EPUBChapterRenderer {
    let archive: ZIPArchive
    let limits: EPUBLimits
    let obfuscatedFontPaths: Set<String>

    private struct RenderContext {
        let chapterDirectory: String
        var styles: [String] = []
        var resourceBytes = 0
    }

    private static let removedElements: Set<String> = [
        "script", "iframe", "frame", "frameset", "object", "embed", "base", "form",
        "input", "button", "select", "option", "optgroup", "textarea", "audio",
        "video", "song", "source", "track", "meta", "noscript", "canvas", "applet",
        "param", "foreignObject"
    ]

    /* 排版可由宿主覆盖：宿主把以下自定义属性内联写在 html/body 上（--foofoil-document-*），
       未设置时回落到这里的默认值；书籍自带的 !important 由 id 选择器压过，自定义属性不影响优先级。 */
    private static let readerCSS = """
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; background: Canvas; color: CanvasText; }
    #foofoil-reader {
      max-width: 44em; margin: 0 auto; padding: 1.4em 1.2em 3em;
      background: Canvas; color: CanvasText;
      line-height: 1.9; word-wrap: break-word; -webkit-text-size-adjust: 100%;
      font-family: var(--foofoil-document-font-family,
        -apple-system, "PingFang SC", "Songti SC", "Noto Serif CJK SC", serif);
    }
    /* 阅读优化：加大行距、压缩段落间距；用 id 提升优先级压过书籍自带的 class !important。 */
    #foofoil-reader, #foofoil-reader p, #foofoil-reader li, #foofoil-reader dd,
    #foofoil-reader dt, #foofoil-reader blockquote {
      line-height: var(--foofoil-document-line-height, 1.9) !important;
    }
    #foofoil-reader p, #foofoil-reader li, #foofoil-reader dd,
    #foofoil-reader blockquote, #foofoil-reader figure {
      margin-top: var(--foofoil-document-paragraph-spacing, 0.25em) !important;
      margin-bottom: var(--foofoil-document-paragraph-spacing, 0.25em) !important;
    }
    /* 正文两端对齐；作者内联标注 text-align 的段落（诗行、图注等显式对齐）保持原样。 */
    #foofoil-reader p:not([style*="text-align" i]),
    #foofoil-reader li:not([style*="text-align" i]),
    #foofoil-reader dd:not([style*="text-align" i]),
    #foofoil-reader dt:not([style*="text-align" i]),
    #foofoil-reader blockquote:not([style*="text-align" i]) {
      text-align: justify !important;
    }
    /* 书籍常设 pre-wrap，源码缩进换行会被显示成空行；正文恢复正常换行，代码块保持原样。 */
    #foofoil-reader, #foofoil-reader p, #foofoil-reader li, #foofoil-reader dd,
    #foofoil-reader dt, #foofoil-reader blockquote, #foofoil-reader div,
    #foofoil-reader td, #foofoil-reader th, #foofoil-reader span {
      white-space: normal !important;
    }
    #foofoil-reader pre, #foofoil-reader pre span,
    #foofoil-reader code, #foofoil-reader code span {
      white-space: pre-wrap !important;
    }
    #foofoil-reader img, #foofoil-reader svg, #foofoil-reader table { max-width: 100%; height: auto; }
    #foofoil-reader pre { word-wrap: break-word; }
    #foofoil-reader a { color: inherit; }
    """

    private static let contentSecurityPolicy = "default-src 'none'; script-src 'none'; "
        + "style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; "
        + "frame-src 'none'; object-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'"

    func render(chapterPath: String, data: Data) throws -> String {
        guard data.count <= limits.maxEntryOutputBytes else { throw EPUBError.limitExceeded }
        guard let text = String(data: data, encoding: .utf8) else { throw EPUBError.chapterRenderingFailed }
        let prepared = try HTMLEntities.preprocess(text)
        guard let preparedData = prepared.data(using: .utf8) else { throw EPUBError.chapterRenderingFailed }
        let document = try EPUBXML.parse(preparedData, limits: limits, failure: .chapterRenderingFailed)
        guard let root = document.rootElement() else {
            throw EPUBError.chapterRenderingFailed
        }
        let body = root.descendants(localName: "body").first ?? root

        var context = RenderContext(chapterDirectory: EPUBPath.directory(of: chapterPath))
        // 处理整棵文档以收集 head 中的样式；只序列化 body 内容。
        try process(element: root, context: &context)
        let content = (body.children ?? []).map(\.xmlString).joined()
        let bookCSS = context.styles.joined(separator: "\n")
        let darkBookCSS = CSSDarkModeTransformer.darkModeCSS(for: bookCSS)
        let html = assemble(content: content, bookStyles: context.styles, darkBookCSS: darkBookCSS)
        guard html.utf8.count <= limits.maxChapterHTMLBytes else { throw EPUBError.limitExceeded }
        return html
    }

    // MARK: - DOM 清理

    private func process(element: XMLElement, context: inout RenderContext) throws {
        for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
            if try handleRemovedElement(child, context: &context) { continue }
            try rewriteAttributes(of: child, context: &context)
            try process(element: child, context: &context)
        }
    }

    private func handleRemovedElement(_ element: XMLElement, context: inout RenderContext) throws -> Bool {
        let tag = element.localName ?? ""
        if Self.removedElements.contains(tag) {
            element.detach()
            return true
        }
        switch tag {
        case "link":
            if (element.attributeValue(localName: "rel") ?? "").lowercased().contains("stylesheet"),
               let href = element.attributeValue(localName: "href"),
               let resource = textResource(for: href, baseDirectory: context.chapterDirectory) {
                let cssDirectory = EPUBPath.directory(of: resource.path)
                context.styles.append(try CSSResourceRewriter.rewrite(resource.css) { reference in
                    try resourceDataURI(reference, baseDirectory: cssDirectory, context: &context)
                })
            }
            element.detach()
            return true
        case "style":
            if let css = element.stringValue, !css.isEmpty {
                context.styles.append(try CSSResourceRewriter.rewrite(css) { reference in
                    try resourceDataURI(reference, baseDirectory: context.chapterDirectory, context: &context)
                })
            }
            element.detach()
            return true
        case "use":
            let reference = element.attributeValue(localName: "href") ?? ""
            if !reference.hasPrefix("#") {
                element.detach()
                return true
            }
            return false
        case "p", "div":
            // 空段落/占位 div 常被书籍用来当空行，直接移除，避免显示成段间空白。
            if Self.isEmptySpacer(element) {
                element.detach()
                return true
            }
            return false
        default:
            return false
        }
    }

    /// 无有效文本、无媒体内容、且不是锚点目标的空块，视为占位空行。
    private static func isEmptySpacer(_ element: XMLElement) -> Bool {
        if element.attributeValue(localName: "id") != nil
            || element.attributeValue(localName: "name") != nil {
            return false
        }
        // 空段落里承载锚点的 <a id/name> 不能当占位删除。
        if !element.descendants(localName: "a").filter({
            $0.attributeValue(localName: "id") != nil || $0.attributeValue(localName: "name") != nil
        }).isEmpty {
            return false
        }
        if let text = element.stringValue {
            let meaningful = text.unicodeScalars.contains { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && scalar != "\u{00A0}" && scalar != "\u{3000}"
                    && scalar != "\u{200B}" && scalar != "\u{FEFF}"
            }
            if meaningful { return false }
        }
        for name in spacerContentNames where !element.descendants(localName: name).isEmpty {
            return false
        }
        return true
    }

    private static let spacerContentNames = [
        "img", "image", "svg", "video", "audio", "object", "iframe", "embed",
        "canvas", "table", "math", "hr"
    ]

    private func rewriteAttributes(of element: XMLElement, context: inout RenderContext) throws {
        let tag = element.localName ?? ""
        for attribute in (element.attributes ?? []) {
            let name = attribute.localName ?? ""
            let value = attribute.stringValue ?? ""
            if name.hasPrefix("on") {
                element.removeAttribute(forName: attribute.name ?? name)
                continue
            }
            switch name {
            case "srcset":
                element.removeAttribute(forName: attribute.name ?? name)
            case "style":
                let transformed = try CSSResourceRewriter.rewrite(value) { reference in
                    try resourceDataURI(reference, baseDirectory: context.chapterDirectory, context: &context)
                }
                setAttribute(element, name: attribute.name ?? name, value: transformed)
            case "src" where tag == "img":
                try applyResourceAttribute(element, attribute: attribute, context: &context, imagesOnly: true)
            case "href" where tag == "image":
                try applyResourceAttribute(element, attribute: attribute, context: &context, imagesOnly: true)
            case "href" where tag == "a", "download" where tag == "a", "target" where tag == "a":
                if !value.hasPrefix("#") {
                    element.removeAttribute(forName: attribute.name ?? name)
                }
            default:
                break
            }
        }
    }

    private func applyResourceAttribute(
        _ element: XMLElement,
        attribute: XMLNode,
        context: inout RenderContext,
        imagesOnly: Bool
    ) throws {
        let name = attribute.name ?? attribute.localName ?? "src"
        let value = attribute.stringValue ?? ""
        guard !value.isEmpty, !value.hasPrefix("data:") else {
            element.removeAttribute(forName: name)
            return
        }
        guard let replacement = try resourceDataURI(
            value,
            baseDirectory: context.chapterDirectory,
            context: &context,
            imagesOnly: imagesOnly
        ) else {
            element.removeAttribute(forName: name)
            return
        }
        setAttribute(element, name: name, value: replacement)
    }

    private func setAttribute(_ element: XMLElement, name: String, value: String) {
        element.removeAttribute(forName: name)
        if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode {
            element.addAttribute(attribute)
        }
    }

    // MARK: - 资源

    private func resourceDataURI(
        _ reference: String,
        baseDirectory: String,
        context: inout RenderContext,
        imagesOnly: Bool = false
    ) throws -> String? {
        guard let resolved = EPUBPath.resolve(reference: reference, relativeTo: baseDirectory),
              resolved.path != "",
              !obfuscatedFontPaths.contains(resolved.path),
              let mime = Self.mimeType(for: resolved.path),
              !imagesOnly || mime.hasPrefix("image/") else { return nil }
        let data: Data
        do {
            data = try archive.data(for: resolved.path)
        } catch EPUBError.limitExceeded {
            throw EPUBError.limitExceeded
        } catch {
            return nil
        }
        guard context.resourceBytes + data.count <= limits.maxChapterResourceBytes else {
            throw EPUBError.limitExceeded
        }
        context.resourceBytes += data.count
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private func textResource(for reference: String, baseDirectory: String) -> (path: String, css: String)? {
        guard let resolved = EPUBPath.resolve(reference: reference, relativeTo: baseDirectory),
              resolved.path != "",
              !obfuscatedFontPaths.contains(resolved.path),
              Self.mimeType(for: resolved.path) == "text/css",
              let data = try? archive.data(for: resolved.path),
              let css = String(data: data, encoding: .utf8) else { return nil }
        return (resolved.path, css)
    }

    static func mimeType(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "otf", "ttc": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "css": return "text/css"
        default: return nil
        }
    }

    // MARK: - 组装

    private func assemble(content: String, bookStyles: [String], darkBookCSS: String) -> String {
        var styles = [Self.readerCSS] + bookStyles
        if !darkBookCSS.isEmpty {
            // 深色外观下覆盖书籍的暗色语法配色；放在书籍样式之后以同优先级胜出。
            styles.append("@media (prefers-color-scheme: dark) {\n\(darkBookCSS)}\n")
        }
        let joined = styles.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(Self.contentSecurityPolicy)">
        <style>
        \(joined)
        </style>
        </head>
        <body id="foofoil-reader">\(content)</body>
        </html>
        """
    }
}
