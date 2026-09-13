//  EPUBContainer.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// OCF 容器：读取 META-INF/container.xml，解析出 OPF rootfile 路径。
public enum EPUBContainer {
    static let containerPath = "META-INF/container.xml"
    static let encryptionPath = "META-INF/encryption.xml"

    public static func rootfilePath(in archive: ZIPArchive, limits: EPUBLimits) throws -> String {
        let data = try archive.data(for: containerPath, maxBytes: 1 << 20)
        let document = try EPUBXML.parse(data, limits: limits, failure: .invalidContainer)
        let rootfiles = document.rootElement()?.descendants(localName: "rootfile") ?? []
        let candidates = rootfiles.filter {
            $0.attributeValue(localName: "media-type") == "application/oebps-package+xml"
        }
        guard let rootfile = candidates.first ?? rootfiles.first,
              let fullPath = rootfile.attributeValue(localName: "full-path"),
              let reference = EPUBPath.resolve(reference: fullPath, relativeTo: ""),
              reference.path != "",
              archive.contains(reference.path) else {
            throw EPUBError.invalidContainer
        }
        return reference.path
    }
}
