//  EBookRuntimeController.swift
//  EBookExtensionRuntime
//
//  Created by 董超 on 2026/9/13.
//

import Darwin
import EBookExtensionCore
import Foundation

enum RuntimeControllerError: Error {
    case invalidSession
    case invalidRequest
    case unsupportedRequest
}

final class EBookRuntimeController: @unchecked Sendable {
    static let extensionID = "app.foofoil.extension.ebook"
    static let providerID = "ebook.epub"
    static let contributionID = "ebook.toc"

    private struct RenderedChapter {
        let url: URL
        let bytes: Int
    }

    private final class SessionRecord {
        let id: UUID
        let request: [String: Any]
        var resourceAccess: RuntimeResourceAccess?
        var document: EPUBDocument?
        var publication: Publication?
        var directory: URL?
        var currentChapterIndex = 0
        var currentItemID: String?
        var revision: UInt64 = 0
        var renderedChapters: [Int: RenderedChapter] = [:]
        var cachedBytes = 0
        /// 结构解析失败时保留稳定 key，restore 必须回同一错误会话。
        var failureKey: String?

        init(id: UUID, request: [String: Any]) {
            self.id = id
            self.request = request
        }
    }

    private let limits: EPUBLimits
    private let lock = NSLock()
    private var sessions: [UUID: SessionRecord] = [:]
    private let directoryManager = RuntimeDirectoryManager()

    init(limits: EPUBLimits = .default) {
        self.limits = limits
    }

    // MARK: - 生命周期

    func createSession(request: [String: Any]) throws -> [String: Any] {
        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              requestData.count <= limits.maxRequestBytes else {
            throw RuntimeControllerError.unsupportedRequest
        }
        guard let resource = try resourceObject(from: request),
              let urlString = resource["url"] as? String,
              let fallbackURL = URL(string: urlString),
              fallbackURL.isFileURL else {
            throw RuntimeControllerError.unsupportedRequest
        }
        let access = RuntimeResourceAccess(resource: resource, fallbackURL: fallbackURL)
        guard access.url.pathExtension.lowercased() == "epub" else {
            throw RuntimeControllerError.unsupportedRequest
        }

        let record = SessionRecord(id: UUID(), request: request)
        record.resourceAccess = access
        let document: EPUBDocument
        do {
            document = try EPUBDocument(url: access.url, limits: limits)
        } catch {
            record.resourceAccess = nil
            return registerFailure(record: record, key: Self.key(for: error))
        }
        record.document = document
        do {
            record.publication = try Publication.make(document: document, limits: limits)
        } catch {
            record.resourceAccess = nil
            record.document = nil
            return registerFailure(record: record, key: Self.key(for: error))
        }

        record.currentChapterIndex = document.firstLinearChapterIndex
        record.currentItemID = record.publication?.nodes.first {
            $0.isEnabled && $0.chapterIndex == record.currentChapterIndex && $0.fragment == nil
        }?.id ?? "spine:\(record.currentChapterIndex)"

        register(record)
        do {
            record.directory = try directoryManager.sessionDirectory(for: record.id)
            let url = try renderChapter(record: record, chapterIndex: record.currentChapterIndex, fragment: nil)
            return sessionObject(record: record, presentationURL: url)
        } catch {
            return chapterFailureSnapshot(record: record, key: Self.key(for: error))
        }
    }

    func perform(navigation: NavigatorActionMessage, session: [String: Any]) throws -> [String: Any] {
        let record = try record(for: session)
        guard let itemID = navigation.action.itemIDs.first,
              let node = record.publication?.node(id: itemID),
              node.isEnabled,
              let chapterIndex = node.chapterIndex else {
            throw RuntimeControllerError.invalidRequest
        }
        lock.lock()
        record.currentItemID = itemID
        record.currentChapterIndex = chapterIndex
        record.revision &+= 1
        lock.unlock()
        do {
            let url = try renderChapter(record: record, chapterIndex: chapterIndex, fragment: node.fragment)
            return sessionObject(record: record, presentationURL: url)
        } catch {
            return chapterFailureSnapshot(record: record, key: Self.key(for: error))
        }
    }

    func perform(lifecycle: SessionLifecycleMessage, session: [String: Any]) throws -> [String: Any] {
        guard let idString = session["id"] as? String, let id = UUID(uuidString: idString) else {
            throw RuntimeControllerError.invalidSession
        }
        switch lifecycle.operation {
        case .close:
            lock.lock()
            let record = sessions.removeValue(forKey: id)
            lock.unlock()
            if let record { cleanup(record) }
            return closedSnapshot(id: id, request: session["request"] as? [String: Any] ?? [:])
        case .restore:
            guard let record = sessionRecord(id: id) else { throw RuntimeControllerError.invalidSession }
            return currentSnapshot(record: record)
        }
    }

    func shutdown() {
        lock.lock()
        let records = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        for record in records { cleanup(record) }
        directoryManager.shutdown()
    }

    // MARK: - 请求

    private func resourceObject(from request: [String: Any]) throws -> [String: Any]? {
        switch request["kind"] as? String {
        case "singleFile":
            return request["resource"] as? [String: Any]
        case "fileCollection":
            let resources = request["resources"] as? [[String: Any]] ?? []
            guard resources.count == 1 else { throw RuntimeControllerError.unsupportedRequest }
            return resources[0]
        default:
            throw RuntimeControllerError.unsupportedRequest
        }
    }

    // MARK: - 快照

    private func register(_ record: SessionRecord) {
        lock.lock()
        sessions[record.id] = record
        lock.unlock()
    }

    private func registerFailure(record: SessionRecord, key: String) -> [String: Any] {
        record.failureKey = key
        record.document = nil
        record.publication = nil
        register(record)
        return unavailableSnapshot(record: record, key: key, capabilities: lifecycleOnlyCapabilities())
    }

    private func record(for session: [String: Any]) throws -> SessionRecord {
        guard (session["providerID"] as? String) == Self.providerID,
              (session["extensionID"] as? String) == Self.extensionID,
              let idString = session["id"] as? String,
              let id = UUID(uuidString: idString),
              let record = sessionRecord(id: id) else {
            throw RuntimeControllerError.invalidSession
        }
        return record
    }

    private func sessionRecord(id: UUID) -> SessionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    private func currentSnapshot(record: SessionRecord) -> [String: Any] {
        if let key = record.failureKey {
            return unavailableSnapshot(record: record, key: key, capabilities: lifecycleOnlyCapabilities())
        }
        if let cached = record.renderedChapters[record.currentChapterIndex] {
            return sessionObject(record: record, presentationURL: cached.url)
        }
        return chapterFailureSnapshot(record: record, key: "EBook Chapter Failed")
    }

    private func unavailableSnapshot(
        record: SessionRecord,
        key: String,
        capabilities: [[String: Any]]
    ) -> [String: Any] {
        [
            "id": record.id.uuidString,
            "extensionID": Self.extensionID,
            "providerID": Self.providerID,
            "request": record.request,
            "presentation": ["kind": "unavailable", "titleKey": "EBook", "messageKey": key],
            "capabilities": capabilities,
            "commands": [],
            "navigatorContributions": []
        ]
    }

    private func chapterFailureSnapshot(record: SessionRecord, key: String) -> [String: Any] {
        [
            "id": record.id.uuidString,
            "extensionID": Self.extensionID,
            "providerID": Self.providerID,
            "request": record.request,
            "presentation": ["kind": "unavailable", "titleKey": "EBook", "messageKey": key],
            "capabilities": activeCapabilities(),
            "commands": [],
            "navigatorContributions": [navigatorObject(record: record)]
        ]
    }

    private func closedSnapshot(id: UUID, request: [String: Any]) -> [String: Any] {
        [
            "id": id.uuidString,
            "extensionID": Self.extensionID,
            "providerID": Self.providerID,
            "request": request,
            "presentation": ["kind": "unavailable", "titleKey": "EBook", "messageKey": "EBook Session Closed"],
            "capabilities": lifecycleOnlyCapabilities(),
            "commands": [],
            "navigatorContributions": []
        ]
    }

    private func sessionObject(record: SessionRecord, presentationURL: URL) -> [String: Any] {
        var object: [String: Any] = [
            "id": record.id.uuidString,
            "extensionID": Self.extensionID,
            "providerID": Self.providerID,
            "request": record.request,
            "presentation": ["kind": "document", "url": presentationURL.absoluteString],
            "capabilities": activeCapabilities(),
            "commands": [],
            "navigatorContributions": [navigatorObject(record: record)]
        ]
        if Self.encodedSize(object) > limits.maxSessionJSONBytes {
            // 原始目录超预算时降级为 spine 目录；仍超限则返回无目录的限制错误会话。
            object["navigatorContributions"] = [spineOnlyNavigatorObject(record: record)]
            if Self.encodedSize(object) > limits.maxSessionJSONBytes {
                object["presentation"] = [
                    "kind": "unavailable", "titleKey": "EBook", "messageKey": "EBook Limit Exceeded"
                ]
                object["navigatorContributions"] = [[String: Any]]()
            }
        }
        return object
    }

    private func navigatorObject(record: SessionRecord, spineOnly: Bool = false) -> [String: Any] {
        let allNodes = record.publication?.nodes ?? []
        let nodes = spineOnly
            ? allNodes.filter { $0.id == "spine:root" || $0.id.hasPrefix("spine:") }
            : allNodes
        let nodeIDs = Set(nodes.map(\.id))
        let selected = record.currentItemID.flatMap { nodeIDs.contains($0) ? $0 : nil }
        let items: [[String: Any]] = nodes.map { node in
            var item: [String: Any] = [
                "id": node.id,
                "title": node.title,
                "isEnabled": node.isEnabled,
                "isCurrent": node.id == selected
            ]
            if let parentID = node.parentID { item["parentID"] = parentID }
            return item
        }
        return [
            "id": Self.contributionID,
            "contractVersion": 1,
            "titleLocalizationKey": "Table of Contents",
            "style": "outline",
            "selectionMode": "single",
            "items": items,
            "selectedItemIDs": selected.map { [$0] } ?? [],
            "allowedActions": ["activate"],
            "revision": record.revision
        ]
    }

    private func spineOnlyNavigatorObject(record: SessionRecord) -> [String: Any] {
        navigatorObject(record: record, spineOnly: true)
    }

    private func activeCapabilities() -> [[String: Any]] {
        [
            capability("ui.navigator", scope: "presentation"),
            capability("ui.navigator-actions", scope: "presentation"),
            capability("session.lifecycle", scope: "session")
        ]
    }

    private func lifecycleOnlyCapabilities() -> [[String: Any]] {
        [capability("session.lifecycle", scope: "session")]
    }

    private func capability(_ id: String, scope: String) -> [String: Any] {
        [
            "declaration": ["id": id, "contractVersion": 1, "scope": scope, "dependencies": []],
            "state": "active"
        ]
    }

    // MARK: - 渲染与文件

    private func renderChapter(record: SessionRecord, chapterIndex: Int, fragment: String?) throws -> URL {
        guard let document = record.document, let directory = record.directory else {
            throw RuntimeControllerError.invalidSession
        }
        guard document.chapters.indices.contains(chapterIndex) else {
            throw RuntimeControllerError.invalidRequest
        }
        let fileURL: URL
        if let cached = record.renderedChapters[chapterIndex],
           FileManager.default.fileExists(atPath: cached.url.path) {
            fileURL = cached.url
        } else {
            let html = try document.renderChapter(at: chapterIndex)
            guard let data = html.data(using: .utf8) else { throw EPUBError.chapterRenderingFailed }
            guard record.cachedBytes + data.count <= limits.maxCachedHTMLBytes else {
                throw EPUBError.limitExceeded
            }
            let target = directory.appendingPathComponent(String(format: "chapter-%04d.html", chapterIndex))
            try data.write(to: target, options: .atomic)
            record.renderedChapters[chapterIndex] = RenderedChapter(url: target, bytes: data.count)
            record.cachedBytes += data.count
            fileURL = target
        }
        return Self.url(fileURL, fragment: fragment)
    }

    private func cleanup(_ record: SessionRecord) {
        if let directory = record.directory {
            try? FileManager.default.removeItem(at: directory)
        }
        record.resourceAccess = nil
    }

    static func url(_ base: URL, fragment: String?) -> URL {
        guard let fragment, !fragment.isEmpty else { return base }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.fragment = fragment.removingPercentEncoding ?? fragment
        return components?.url ?? base
    }

    static func key(for error: Error) -> String {
        guard let epubError = error as? EPUBError else { return "EBook Chapter Failed" }
        switch epubError {
        case .invalidArchive, .invalidContainer, .invalidPackage, .missingResource:
            return "EBook Invalid EPUB"
        case .encrypted:
            return "EBook Encrypted Unsupported"
        case .unsupportedContent:
            return "EBook Unsupported Content"
        case .limitExceeded:
            return "EBook Limit Exceeded"
        case .chapterRenderingFailed:
            return "EBook Chapter Failed"
        }
    }

    private static func encodedSize(_ object: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: object).count) ?? Int.max
    }
}

/// 解析书签并持有安全范围访问至会话关闭。
private final class RuntimeResourceAccess: @unchecked Sendable {
    let url: URL
    private let didStartAccess: Bool

    init(resource: [String: Any], fallbackURL: URL) {
        if let bookmarkString = resource["securityScopedBookmark"] as? String,
           let bookmark = Data(base64Encoded: bookmarkString) {
            var stale = false
            url = (try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &stale
            )) ?? fallbackURL
        } else {
            url = fallbackURL
        }
        didStartAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess { url.stopAccessingSecurityScopedResource() }
    }
}

/// 每 runtime 独立临时根：全程持 advisory lock，启动时只回收未被活实例加锁的旧目录。
final class RuntimeDirectoryManager: @unchecked Sendable {
    let root: URL
    private var lockDescriptor: Int32 = -1

    init() {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-ebook", isDirectory: true)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        Self.sweep(parent: parent)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        lockDescriptor = Self.lockDirectory(root)
    }

    func sessionDirectory(for id: UUID) throws -> URL {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func shutdown() {
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func lockDirectory(_ url: URL) -> Int32 {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return -1 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return -1
        }
        return descriptor
    }

    private static func sweep(parent: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: Array(keys)
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for child in children {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            let descriptor = open(child.path, O_RDONLY)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try? FileManager.default.removeItem(at: child)
                flock(descriptor, LOCK_UN)
            }
            close(descriptor)
        }
    }
}
