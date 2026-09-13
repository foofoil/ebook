//  XMLSupport.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// 统一的 XML 解析入口：SAX 预检节点数/深度，再构造 DOM；始终禁止外部实体与外部 DTD。
enum EPUBXML {
    static func parse(_ data: Data, limits: EPUBLimits, failure: EPUBError) throws -> XMLDocument {
        try precheck(data, limits: limits, failure: failure)
        guard let document = try? XMLDocument(
            data: data,
            options: [.nodeLoadExternalEntitiesNever]
        ) else {
            throw failure
        }
        return document
    }

    private static func precheck(_ data: Data, limits: EPUBLimits, failure: EPUBError) throws {
        let scanner = SafetyScanner(limits: limits)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = scanner
        guard parser.parse(), !scanner.exceeded else {
            throw scanner.exceeded ? EPUBError.limitExceeded : failure
        }
    }

    private final class SafetyScanner: NSObject, XMLParserDelegate {
        let limits: EPUBLimits
        private(set) var exceeded = false
        private var depth = 0
        private var nodes = 0

        init(limits: EPUBLimits) {
            self.limits = limits
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes: [String: String]
        ) {
            depth += 1
            nodes += 1
            if depth > limits.maxXMLDepth || nodes > limits.maxXMLNodeCount {
                exceeded = true
                parser.abortParsing()
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            depth = max(0, depth - 1)
        }
    }
}

extension XMLNode {
    /// 命名空间无关的元素匹配：只要 localName 相同，不依赖作者使用的固定前缀。
    func firstElement(localName name: String) -> XMLElement? {
        elements(forLocalName: name).first
    }

    func elements(forLocalName name: String) -> [XMLElement] {
        guard let element = self as? XMLElement else { return [] }
        return (element.children ?? []).compactMap { child in
            guard let childElement = child as? XMLElement, childElement.localName == name else { return nil }
            return childElement
        }
    }

    func descendants(localName name: String) -> [XMLElement] {
        guard let element = self as? XMLElement else { return [] }
        var result: [XMLElement] = []
        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }
            if childElement.localName == name { result.append(childElement) }
            result.append(contentsOf: childElement.descendants(localName: name))
        }
        return result
    }

    func descendants(localName name: String, attributeLocalName attribute: String, value: String) -> [XMLElement] {
        descendants(localName: name).filter { element in
            element.attributeValue(localName: attribute) == value
        }
    }

    func attributeValue(localName name: String) -> String? {
        guard let element = self as? XMLElement else { return nil }
        return (element.attributes ?? []).first { $0.localName == name }?.stringValue
    }

    var trimmedText: String {
        (stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
