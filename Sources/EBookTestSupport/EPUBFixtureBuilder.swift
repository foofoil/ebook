//  EPUBFixtureBuilder.swift
//  EBookTestSupport
//
//  Created by 董超 on 2026/9/13.
//

import Compression
import EBookExtensionCore
import Foundation

/// 生成可独立分发的测试 EPUB；条目可分别选择 stored 或 deflate。
public struct EPUBFixtureBuilder {
    public struct Entry {
        public let name: String
        public let data: Data
        public let compress: Bool

        public init(name: String, data: Data, compress: Bool = false) {
            self.name = name
            self.data = data
            self.compress = compress
        }

        public init(name: String, text: String, compress: Bool = false) {
            self.init(name: name, data: Data(text.utf8), compress: compress)
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func add(name: String, data: Data, compress: Bool = false) {
        entries.append(Entry(name: name, data: data, compress: compress))
    }

    public mutating func add(name: String, text: String, compress: Bool = false) {
        entries.append(Entry(name: name, text: text, compress: compress))
    }

    public func build() throws -> Data {
        try ZIPWriter(entries: entries).build()
    }

    /// 最小 EPUB3：两级 nav、两张正文、CSS 与 1×1 PNG。
    public static func minimalEPUB3(
        title: String = "测试书",
        creator: String = "测试作者",
        compress: Bool = true,
        extraChapterBody: String = ""
    ) -> Data {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip", compress: false)
        builder.add(name: "META-INF/container.xml", text: containerXML, compress: compress)
        builder.add(name: "OEBPS/content.opf", text: epub3OPF(title: title, creator: creator), compress: compress)
        builder.add(name: "OEBPS/nav.xhtml", text: epub3Nav, compress: compress)
        builder.add(name: "OEBPS/chapter1.xhtml", text: chapterOne(extra: extraChapterBody), compress: compress)
        builder.add(name: "OEBPS/chapter2.xhtml", text: chapterTwo, compress: compress)
        builder.add(name: "OEBPS/style.css", text: sampleCSS, compress: compress)
        builder.add(name: "OEBPS/images/pixel.png", data: Self.pixelPNG, compress: compress)
        return (try? builder.build()) ?? Data()
    }

    /// 最小 EPUB2：spine 引用 NCX 目录。
    public static func minimalEPUB2(title: String = "旧版书", compress: Bool = true) -> Data {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip", compress: false)
        builder.add(name: "META-INF/container.xml", text: containerXML, compress: compress)
        builder.add(name: "OEBPS/content.opf", text: epub2OPF(title: title), compress: compress)
        builder.add(name: "OEBPS/toc.ncx", text: epub2NCX, compress: compress)
        builder.add(name: "OEBPS/chapter1.xhtml", text: chapterOne(extra: ""), compress: compress)
        builder.add(name: "OEBPS/chapter2.xhtml", text: chapterTwo, compress: compress)
        return (try? builder.build()) ?? Data()
    }

    public static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    public static func epub3OPF(title: String, creator: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:creator>\(creator)</dc:creator>
            <dc:language>zh</dc:language>
            <dc:identifier id="bookid">urn:uuid:00000000-0000-4000-8000-000000000001</dc:identifier>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            <item id="pixel" href="images/pixel.png" media-type="image/png"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """
    }

    public static func epub2OPF(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:language>zh</dc:language>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="c1"/>
            <itemref idref="c2" linear="no"/>
          </spine>
        </package>
        """
    }

    public static let epub3Nav = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>目录</title></head>
      <body>
        <nav epub:type="toc" id="toc">
          <ol>
            <li><a href="chapter1.xhtml">第一章</a>
              <ol>
                <li><a href="chapter1.xhtml#s1">第一节</a></li>
                <li><a href="chapter1.xhtml#s2">第二节</a></li>
              </ol>
            </li>
            <li><a href="chapter2.xhtml">第二章</a></li>
          </ol>
        </nav>
      </body>
    </html>
    """

    public static let epub2NCX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <navMap>
        <navPoint id="n1" playOrder="1">
          <navLabel><text>第一章</text></navLabel>
          <content src="chapter1.xhtml"/>
          <navPoint id="n1-1" playOrder="2">
            <navLabel><text>第一节</text></navLabel>
            <content src="chapter1.xhtml#s1"/>
          </navPoint>
        </navPoint>
        <navPoint id="n2" playOrder="3">
          <navLabel><text>第二章</text></navLabel>
          <content src="chapter2.xhtml"/>
        </navPoint>
      </navMap>
    </ncx>
    """

    public static let sampleCSS = """
    p { color: #333333; }
    body { background-image: url('images/pixel.png'); }
    """

    public static func chapterOne(extra: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head>
            <title>第一章</title>
            <link rel="stylesheet" type="text/css" href="style.css"/>
            <script>alert("blocked")</script>
            <style>h1 { color: #111111; }</style>
          </head>
          <body>
            <h1 id="s0">第一章</h1>
            <h2 id="s1">第一节</h2>
            <h3 id="s2">第二节</h3>
            <p>正文内容&nbsp;与实体&hellip;</p>
            <p><img src="images/pixel.png" alt="像素"/></p>
            <p><a href="chapter2.xhtml">下一章</a> <a href="#s1">回到第一节</a></p>
            \(extra)
          </body>
        </html>
        """
    }

    public static let chapterTwo = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>第二章</title></head>
      <body>
        <h1 id="s0">第二章</h1>
        <p>第二章正文。</p>
      </body>
    </html>
    """

    /// 字体混淆夹具：encryption.xml + 可被 CSS 引用的字体。
    public static func obfuscatedFontEPUB(
        algorithm: String = "http://www.idpf.org/2008/embedding",
        target: String = "OEBPS/font.ttf"
    ) -> Data {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: containerXML)
        builder.add(name: "META-INF/encryption.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="\(algorithm)"/>
            <enc:CipherData><enc:CipherReference URI="\(target)"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """)
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>字体书</dc:title></metadata>
          <manifest>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="f1" href="font.ttf" media-type="font/ttf"/>
            <item id="css" href="style.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """)
        builder.add(name: "OEBPS/c1.xhtml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>第一章</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
          <body><h1>第一章</h1><p>字体混淆仍可阅读。</p></body>
        </html>
        """)
        builder.add(name: "OEBPS/style.css", text: """
        @font-face { font-family: BookFont; src: url(font.ttf); }
        body { font-family: BookFont, serif; }
        """)
        builder.add(name: "OEBPS/font.ttf", data: Data(repeating: 0x5F, count: 128))
        return (try? builder.build()) ?? Data()
    }

    /// 带封面的最小 EPUB。style: "epub3"（cover-image 属性）、"epub2"（meta cover）、"guide"（guide→xhtml→img）。
    public static func coverEPUB(style: String = "epub3") -> Data {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "mimetype", text: "application/epub+zip")
        builder.add(name: "META-INF/container.xml", text: containerXML)
        let coverItem = style == "epub3"
            ? "<item id=\"cover\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>"
            : "<item id=\"coverimg\" href=\"cover.png\" media-type=\"image/png\"/>"
        let meta = style == "epub2" ? "<meta name=\"cover\" content=\"coverimg\"/>" : ""
        let guide = style == "guide" ? "<guide><reference type=\"cover\" href=\"coverpage.xhtml\"/></guide>" : ""
        builder.add(name: "OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>封面书</dc:title>\(meta)
          </metadata>
          <manifest>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            \(coverItem)
          </manifest>
          <spine><itemref idref="c1"/></spine>\(guide)
        </package>
        """)
        builder.add(name: "OEBPS/chapter1.xhtml", text: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>正文</p></body></html>")
        if style == "guide" {
            builder.add(name: "OEBPS/coverpage.xhtml", text: """
            <html xmlns="http://www.w3.org/1999/xhtml"><body><img src="cover.png" alt="cover"/></body></html>
            """)
        }
        builder.add(name: "OEBPS/cover.png", data: pixelPNG)
        return (try? builder.build()) ?? Data()
    }

    /// 1×1 透明 PNG。
    public static let pixelPNG: Data = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    ) ?? Data()
}

/// 极简 ZIP 写入器：供夹具生成，支持 stored 与 raw DEFLATE。
public struct ZIPWriter {
    public let entries: [EPUBFixtureBuilder.Entry]

    public init(entries: [EPUBFixtureBuilder.Entry]) {
        self.entries = entries
    }

    public func build() throws -> Data {
        var output = Data()
        var offsets: [Int] = []
        for entry in entries {
            offsets.append(output.count)
            output.append(makeLocalHeader(entry))
            output.append(entry.compress ? Self.deflate(entry.data) : entry.data)
        }
        let centralOffset = output.count
        for (index, entry) in entries.enumerated() {
            output.append(makeCentralEntry(entry, offset: offsets[index]))
        }
        let centralSize = output.count - centralOffset
        output.append(Self.u32(0x06054b50))
        output.append(Self.u16(0))
        output.append(Self.u16(0))
        output.append(Self.u16(UInt16(entries.count)))
        output.append(Self.u16(UInt16(entries.count)))
        output.append(Self.u32(UInt32(centralSize)))
        output.append(Self.u32(UInt32(centralOffset)))
        output.append(Self.u16(0))
        return output
    }

    private func payload(_ entry: EPUBFixtureBuilder.Entry) -> (data: Data, method: UInt16) {
        if entry.compress, !entry.data.isEmpty {
            return (Self.deflate(entry.data), 8)
        }
        return (entry.data, 0)
    }

    private func makeLocalHeader(_ entry: EPUBFixtureBuilder.Entry) -> Data {
        let (data, method) = payload(entry)
        var header = Data()
        header.append(Self.u32(0x04034b50))
        header.append(Self.u16(method == 8 ? 20 : 10))
        header.append(Self.u16(0))
        header.append(Self.u16(method))
        header.append(Self.u16(0))
        header.append(Self.u16(0))
        header.append(Self.u32(ZIPCRC32.checksum(entry.data)))
        header.append(Self.u32(UInt32(data.count)))
        header.append(Self.u32(UInt32(entry.data.count)))
        header.append(Self.u16(UInt16(entry.name.utf8.count)))
        header.append(Self.u16(0))
        header.append(Data(entry.name.utf8))
        return header
    }

    private func makeCentralEntry(_ entry: EPUBFixtureBuilder.Entry, offset: Int) -> Data {
        let (data, method) = payload(entry)
        var header = Data()
        header.append(Self.u32(0x02014b50))
        header.append(Self.u16(20))
        header.append(Self.u16(method == 8 ? 20 : 10))
        header.append(Self.u16(0))
        header.append(Self.u16(method))
        header.append(Self.u16(0))
        header.append(Self.u16(0))
        header.append(Self.u32(ZIPCRC32.checksum(entry.data)))
        header.append(Self.u32(UInt32(data.count)))
        header.append(Self.u32(UInt32(entry.data.count)))
        header.append(Self.u16(UInt16(entry.name.utf8.count)))
        header.append(Self.u16(0))
        header.append(Self.u16(0))
        header.append(Self.u16(0))
        header.append(Self.u16(0))
        header.append(Self.u32(0))
        header.append(Self.u32(UInt32(offset)))
        header.append(Data(entry.name.utf8))
        return header
    }

    static func deflate(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return input }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        input.withUnsafeBytes { source in
            streamPointer.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
            streamPointer.pointee.src_size = source.count
            var status = COMPRESSION_STATUS_OK
            repeat {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = bufferSize
                status = compression_stream_process(
                    streamPointer,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 { output.append(buffer, count: produced) }
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }

    static func u16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
