//  EPUBPackage.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

public struct EPUBManifestItem: Sendable {
    public let id: String
    public let path: String
    public let mediaType: String
    public let properties: Set<String>
}

public struct EPUBSpineItem: Sendable {
    public let path: String
    public let mediaType: String
    public let linear: Bool
    public let manifestID: String
}

public struct EPUBPackage: Sendable {
    public let opfPath: String
    public let title: String?
    public let creators: [String]
    public let language: String?
    public let manifest: [String: EPUBManifestItem]
    public let spine: [EPUBSpineItem]
    public let ncxItemID: String?
    public let obfuscatedFontPaths: Set<String>

    public static func parse(archive: ZIPArchive, opfPath: String, limits: EPUBLimits) throws -> EPUBPackage {
        let data = try archive.data(for: opfPath, maxBytes: 8 << 20)
        let document = try EPUBXML.parse(data, limits: limits, failure: .invalidPackage)
        guard let root = document.rootElement() else { throw EPUBError.invalidPackage }
        let baseDirectory = EPUBPath.directory(of: opfPath)

        // metadata
        let metadata = root.descendants(localName: "metadata").first
        let titles = metadata?.descendants(localName: "title").map(\.trimmedText).filter { !$0.isEmpty } ?? []
        let creators = metadata?.descendants(localName: "creator").map(\.trimmedText).filter { !$0.isEmpty } ?? []
        let languages = metadata?.descendants(localName: "language").map(\.trimmedText).filter { !$0.isEmpty } ?? []

        // manifest
        guard let manifestElement = root.descendants(localName: "manifest").first else {
            throw EPUBError.invalidPackage
        }
        var manifest: [String: EPUBManifestItem] = [:]
        for item in manifestElement.elements(forLocalName: "item") {
            guard let id = item.attributeValue(localName: "id"), !id.isEmpty,
                  let href = item.attributeValue(localName: "href"),
                  let reference = EPUBPath.resolve(reference: href, relativeTo: baseDirectory),
                  reference.path != "" else { throw EPUBError.invalidPackage }
            guard manifest[id] == nil else { throw EPUBError.invalidPackage }
            let mediaType = (item.attributeValue(localName: "media-type") ?? "").lowercased()
            let properties = Set(
                (item.attributeValue(localName: "properties") ?? "")
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
            )
            manifest[id] = EPUBManifestItem(
                id: id,
                path: reference.path,
                mediaType: mediaType,
                properties: properties
            )
        }

        // spine
        guard let spineElement = root.descendants(localName: "spine").first else {
            throw EPUBError.invalidPackage
        }
        var spine: [EPUBSpineItem] = []
        for itemref in spineElement.elements(forLocalName: "itemref") {
            guard let idref = itemref.attributeValue(localName: "idref"), !idref.isEmpty else {
                throw EPUBError.invalidPackage
            }
            guard let item = manifest[idref] else { throw EPUBError.invalidPackage }
            guard item.mediaType == "application/xhtml+xml" else { throw EPUBError.unsupportedContent }
            let linear = (itemref.attributeValue(localName: "linear") ?? "yes").lowercased() != "no"
            spine.append(EPUBSpineItem(
                path: item.path,
                mediaType: item.mediaType,
                linear: linear,
                manifestID: item.id
            ))
        }
        guard !spine.isEmpty else { throw EPUBError.invalidPackage }

        let obfuscatedFonts = try EPUBEncryption.obfuscatedFontPaths(
            archive: archive,
            limits: limits,
            manifest: manifest
        )

        return EPUBPackage(
            opfPath: opfPath,
            title: titles.first,
            creators: creators,
            language: languages.first,
            manifest: manifest,
            spine: spine,
            ncxItemID: spineElement.attributeValue(localName: "toc"),
            obfuscatedFontPaths: obfuscatedFonts
        )
    }

    public func manifestItem(forPath path: String) -> EPUBManifestItem? {
        manifest.values.first { $0.path == path }
    }

    public func navItem() -> EPUBManifestItem? {
        manifest.values.first { $0.properties.contains("nav") }
    }
}

/// encryption.xml：仅识别字体混淆并降级为系统字体；其它加密算法明确拒绝。
enum EPUBEncryption {
    static func obfuscatedFontPaths(
        archive: ZIPArchive,
        limits: EPUBLimits,
        manifest: [String: EPUBManifestItem]
    ) throws -> Set<String> {
        guard archive.contains(EPUBContainer.encryptionPath) else { return [] }
        let data = try archive.data(for: EPUBContainer.encryptionPath, maxBytes: 4 << 20)
        let document = try EPUBXML.parse(data, limits: limits, failure: .invalidPackage)
        let encryptedItems = document.rootElement()?.descendants(localName: "EncryptedData") ?? []
        var result = Set<String>()
        for encrypted in encryptedItems {
            let algorithm = encrypted.descendants(localName: "EncryptionMethod")
                .first?.attributeValue(localName: "Algorithm")
            guard algorithm == "http://www.idpf.org/2008/embedding"
                    || algorithm == "http://ns.adobe.com/pdf/enc#RC" else {
                throw EPUBError.encrypted
            }
            guard let uri = encrypted.descendants(localName: "CipherReference")
                .first?.attributeValue(localName: "URI"),
                let reference = EPUBPath.resolve(reference: uri, relativeTo: ""),
                reference.path != "",
                let item = manifest.values.first(where: { $0.path == reference.path }),
                item.mediaType == "font/ttf" || item.mediaType == "font/otf"
                    || item.mediaType == "application/font-sfnt"
                    || item.mediaType == "application/vnd.ms-opentype"
                    || item.mediaType == "application/x-font-ttf" else {
                throw EPUBError.encrypted
            }
            result.insert(reference.path)
        }
        return result
    }
}
