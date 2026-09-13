//  main.swift
//  EBookRuntimeSmoke
//
//  Created by 董超 on 2026/9/13.
//

import EBookTestSupport
import FoofoilExtensionKit
import Foundation

private typealias RuntimeCall = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int>?
) -> Int32
private typealias ReleaseCall = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int) -> Void
private typealias DestroyCall = @convention(c) (UnsafeMutableRawPointer?) -> Void

private struct RuntimeInterfaceV1 {
    let apiVersion: UInt32
    let structSize: Int
    let context: UnsafeMutableRawPointer?
    let createSession: RuntimeCall?
    let performCommand: RuntimeCall?
    let releaseBytes: ReleaseCall?
    let destroy: DestroyCall?
    let performApplicationCommand: RuntimeCall?
}

@_silgen_name("foofoil_extension_create")
private func createRuntime(_ version: UInt32) -> UnsafeRawPointer?

private enum SmokeError: Error, CustomStringConvertible {
    case runtimeUnavailable
    case invalidInterface
    case callFailed(Int32)
    case unexpected(String)

    var description: String {
        switch self {
        case .runtimeUnavailable: "runtime unavailable"
        case .invalidInterface: "invalid interface"
        case .callFailed(let status): "ABI call failed with status \(status)"
        case .unexpected(let message): message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SmokeError.unexpected(message) }
}

private struct Harness {
    let interface: UnsafePointer<RuntimeInterfaceV1>

    init() throws {
        guard let raw = createRuntime(1) else { throw SmokeError.runtimeUnavailable }
        interface = raw.assumingMemoryBound(to: RuntimeInterfaceV1.self)
        guard interface.pointee.apiVersion == 1,
              interface.pointee.structSize >= MemoryLayout<RuntimeInterfaceV1>.size,
              interface.pointee.createSession != nil,
              interface.pointee.performCommand != nil,
              interface.pointee.releaseBytes != nil else {
            throw SmokeError.invalidInterface
        }
    }

    @discardableResult
    func call(
        _ function: RuntimeCall?,
        message: [String: Any]
    ) throws -> (status: Int32, object: [String: Any]?) {
        guard let function else { throw SmokeError.invalidInterface }
        let data = try JSONSerialization.data(withJSONObject: message)
        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        let status = data.withUnsafeBytes { bytes in
            function(
                interface.pointee.context,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &output,
                &outputLength
            )
        }
        var object: [String: Any]?
        if status == 0, let output, outputLength > 0 {
            object = try JSONSerialization.jsonObject(
                with: Data(bytes: output, count: outputLength)
            ) as? [String: Any]
        }
        if let output {
            interface.pointee.releaseBytes?(interface.pointee.context, output, outputLength)
        }
        return (status, object)
    }

    func createSession(_ request: [String: Any]) throws -> (status: Int32, session: ContentSession?) {
        let (status, object) = try call(interface.pointee.createSession, message: request)
        guard let object else { return (status, nil) }
        let data = try JSONSerialization.data(withJSONObject: object)
        return (status, try JSONDecoder().decode(ContentSession.self, from: data))
    }

    func perform(_ request: some Encodable) throws -> (status: Int32, session: ContentSession?) {
        let message = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] ?? [:]
        let (status, object) = try call(interface.pointee.performCommand, message: message)
        guard let object else { return (status, nil) }
        let data = try JSONSerialization.data(withJSONObject: object)
        return (status, try JSONDecoder().decode(ContentSession.self, from: data))
    }

    func performRaw(_ message: [String: Any]) throws -> Int32 {
        try call(interface.pointee.performCommand, message: message).status
    }
}

private func presentationFileURL(_ session: ContentSession) throws -> URL {
    guard case .document(let url) = session.presentation else {
        throw SmokeError.unexpected("expected document presentation")
    }
    guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
        throw SmokeError.unexpected("document file missing: \(url.path)")
    }
    return url
}

do {
    let harness = try Harness()
    let fixtureURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("foofoil-ebook-smoke-\(UUID().uuidString).epub")
    try EPUBFixtureBuilder.minimalEPUB3().write(to: fixtureURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: fixtureURL) }

    let request: [String: Any] = [
        "kind": "singleFile",
        "resource": ["url": fixtureURL.absoluteString]
    ]
    let (createStatus, created) = try harness.createSession(request)
    try expect(createStatus == 0, "createSession status \(createStatus)")
    guard let session = created else { throw SmokeError.unexpected("missing session") }
    try expect(session.providerID == "ebook.epub", "providerID")
    try expect(session.extensionID == "app.foofoil.extension.ebook", "extensionID")
    try expect(session.navigatorContributions.count == 1, "navigator count")
    let toc = session.navigatorContributions[0]
    try NavigatorContributionValidator.validate(toc)
    try expect(toc.style == .outline, "outline style")
    try expect(toc.selectedItemIDs == ["toc:0"], "initial selection \(toc.selectedItemIDs)")
    try expect(toc.items.contains { $0.id == "spine:root" && !$0.isEnabled }, "spine root disabled")
    let firstFile = try presentationFileURL(session)

    // 同章不同 fragment。
    let fragmentAction = NavigatorActionRequest(
        action: NavigatorAction(contributionID: "ebook.toc", kind: .activate, itemIDs: ["toc:0.1"]),
        session: session
    )
    let (fragmentStatus, fragmentSession) = try harness.perform(fragmentAction)
    try expect(fragmentStatus == 0, "fragment status \(fragmentStatus)")
    guard let fragmented = fragmentSession else { throw SmokeError.unexpected("missing fragment session") }
    guard case .document(let fragmentURL) = fragmented.presentation else {
        throw SmokeError.unexpected("fragment presentation")
    }
    try expect(fragmentURL.fragment == "s2", "fragment \(fragmentURL.fragment ?? "nil")")
    try expect(fragmentURL.path == firstFile.path, "same chapter file")

    // 跨章切换。
    let chapterAction = NavigatorActionRequest(
        action: NavigatorAction(contributionID: "ebook.toc", kind: .activate, itemIDs: ["toc:1"]),
        session: fragmented
    )
    let (chapterStatus, chapterSession) = try harness.perform(chapterAction)
    try expect(chapterStatus == 0, "chapter status \(chapterStatus)")
    guard let second = chapterSession else { throw SmokeError.unexpected("missing chapter session") }
    let secondFile = try presentationFileURL(second)
    try expect(secondFile.path != firstFile.path, "chapter file should change")
    try expect(second.navigatorContributions[0].selectedItemIDs == ["toc:1"], "selection after chapter")

    // 禁用条目拒绝。
    let disabledAction = NavigatorActionRequest(
        action: NavigatorAction(contributionID: "ebook.toc", kind: .activate, itemIDs: ["spine:root"]),
        session: second
    )
    let (disabledStatus, _) = try harness.perform(disabledAction)
    try expect(disabledStatus != 0, "disabled item accepted")

    // 未知名命令拒绝。
    let rawStatus = try harness.performRaw(["commandID": "unknown.command", "session": [:], "contractVersion": 1])
    try expect(rawStatus == 1, "unknown command status \(rawStatus)")

    // restore 返回同一会话，不重建。
    let restore = SessionLifecycleRequest(
        operation: .restore, session: second,
        restoration: PlaybackRestorationState()
    )
    let (restoreStatus, restored) = try harness.perform(restore)
    try expect(restoreStatus == 0, "restore status \(restoreStatus)")
    guard let restored else { throw SmokeError.unexpected("missing restored session") }
    try expect(restored.id == second.id, "restore UUID")
    guard case .document(let restoredURL) = restored.presentation else {
        throw SmokeError.unexpected("restore presentation")
    }
    try expect(restoredURL == secondFile, "restore URL")

    // 双文件请求拒绝。
    let (collectionStatus, _) = try harness.createSession([
        "kind": "fileCollection",
        "resources": [["url": fixtureURL.absoluteString], ["url": fixtureURL.absoluteString]]
    ])
    try expect(collectionStatus == 2, "collection status \(collectionStatus)")

    // 第二会话独立；关闭一个不影响另一个。
    let (secondCreateStatus, secondCreated) = try harness.createSession(request)
    try expect(secondCreateStatus == 0, "second create \(secondCreateStatus)")
    guard let independent = secondCreated else { throw SmokeError.unexpected("missing second session") }
    let independentFile = try presentationFileURL(independent)
    let closeIndependent = SessionLifecycleRequest(operation: .close, session: independent)
    let (closeIndependentStatus, closedIndependent) = try harness.perform(closeIndependent)
    try expect(closeIndependentStatus == 0, "close independent \(closeIndependentStatus)")
    guard let closedIndependent else { throw SmokeError.unexpected("missing closed snapshot") }
    try expect(closedIndependent.navigatorContributions.isEmpty, "closed navigator")
    try expect(!FileManager.default.fileExists(atPath: independentFile.deletingLastPathComponent().path),
               "independent directory removed")
    try expect(FileManager.default.fileExists(atPath: secondFile.path), "other session file removed")

    // 关闭幂等，关闭后动作不得复活。
    let (repeatCloseStatus, _) = try harness.perform(SessionLifecycleRequest(operation: .close, session: closedIndependent))
    try expect(repeatCloseStatus == 0, "repeat close \(repeatCloseStatus)")
    let afterClose = NavigatorActionRequest(
        action: NavigatorAction(contributionID: "ebook.toc", kind: .activate, itemIDs: ["toc:0"]),
        session: closedIndependent
    )
    let (afterCloseStatus, _) = try harness.perform(afterClose)
    try expect(afterCloseStatus != 0, "activate after close accepted")

    // 非法契约版本、未知会话与带 restoration 的 close 都必须被拒绝。
    let badVersion = try harness.performRaw([
        "commandID": "ui.navigator.action",
        "contractVersion": 2,
        "action": ["contributionID": "ebook.toc", "kind": "activate", "itemIDs": ["toc:0"]],
        "session": [
            "id": second.id.uuidString,
            "extensionID": "app.foofoil.extension.ebook",
            "providerID": "ebook.epub",
            "request": [:],
            "presentation": ["kind": "text", "titleKey": "x", "body": "y"]
        ]
    ])
    try expect(badVersion == 1, "bad contract version status \(badVersion)")

    let unknownSession = try harness.performRaw([
        "commandID": "session.lifecycle",
        "contractVersion": 1,
        "operation": "restore",
        "restoration": [:],
        "session": [
            "id": UUID().uuidString,
            "extensionID": "app.foofoil.extension.ebook",
            "providerID": "ebook.epub",
            "request": [:],
            "presentation": ["kind": "text", "titleKey": "x", "body": "y"]
        ]
    ])
    try expect(unknownSession == 1, "unknown session status \(unknownSession)")

    let closeWithRestoration = try harness.performRaw([
        "commandID": "session.lifecycle",
        "contractVersion": 1,
        "operation": "close",
        "restoration": [:],
        "session": [
            "id": second.id.uuidString,
            "extensionID": "app.foofoil.extension.ebook",
            "providerID": "ebook.epub",
            "request": [:],
            "presentation": ["kind": "text", "titleKey": "x", "body": "y"]
        ]
    ])
    try expect(closeWithRestoration == 1, "close with restoration status \(closeWithRestoration)")

    // 损坏文件返回错误会话并可关闭。
    let brokenURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("foofoil-ebook-broken-\(UUID().uuidString).epub")
    try Data(repeating: 0x5A, count: 256).write(to: brokenURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: brokenURL) }
    let (brokenStatus, broken) = try harness.createSession([
        "kind": "singleFile",
        "resource": ["url": brokenURL.absoluteString]
    ])
    try expect(brokenStatus == 0, "broken create \(brokenStatus)")
    guard let broken else { throw SmokeError.unexpected("missing broken session") }
    guard case .unavailable = broken.presentation else {
        throw SmokeError.unexpected("broken presentation")
    }
    let (brokenCloseStatus, _) = try harness.perform(SessionLifecycleRequest(operation: .close, session: broken))
    try expect(brokenCloseStatus == 0, "broken close \(brokenCloseStatus)")

    // 关闭主会话后目录删除；destroy 兜底清理其余文件。
    let (closeStatus, _) = try harness.perform(SessionLifecycleRequest(operation: .close, session: second))
    try expect(closeStatus == 0, "close status \(closeStatus)")
    try expect(!FileManager.default.fileExists(atPath: secondFile.deletingLastPathComponent().path),
               "session directory removed")
    harness.interface.pointee.destroy?(harness.interface.pointee.context)

    print("ebook-runtime-smoke passed")
} catch {
    FileHandle.standardError.write(Data("ebook-runtime-smoke failed: \(error)\n".utf8))
    exit(1)
}
