//  Runtime.swift
//  EBookExtensionRuntime
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
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
    var apiVersion: UInt32
    var structSize: Int
    var context: UnsafeMutableRawPointer?
    var createSession: RuntimeCall?
    var performCommand: RuntimeCall?
    var releaseBytes: ReleaseCall?
    var destroy: DestroyCall?
    var performApplicationCommand: RuntimeCall?
}

private enum RuntimeStatus {
    static let success: Int32 = 0
    static let invalidMessage: Int32 = 1
    static let unsupportedRequest: Int32 = 2
    static let processingFailed: Int32 = 3
}

private let createSessionCallback: RuntimeCall = { _, input, inputLength, output, outputLength in
    runtimeControlLock.lock()
    defer { runtimeControlLock.unlock() }
    guard let request = jsonObject(input, length: inputLength) else {
        return RuntimeStatus.invalidMessage
    }
    do {
        let session = try runtimeController.createSession(request: request)
        return writeJSON(session, to: output, length: outputLength)
    } catch RuntimeControllerError.unsupportedRequest {
        return RuntimeStatus.unsupportedRequest
    } catch {
        return RuntimeStatus.processingFailed
    }
}

private let performCommandCallback: RuntimeCall = { _, input, inputLength, output, outputLength in
    runtimeControlLock.lock()
    defer { runtimeControlLock.unlock() }
    guard let input, let message = jsonObject(input, length: inputLength),
          let commandID = message["commandID"] as? String,
          let session = message["session"] as? [String: Any] else {
        return RuntimeStatus.invalidMessage
    }
    let data = Data(bytes: input, count: inputLength)
    let response: [String: Any]
    do {
        switch commandID {
        case "ui.navigator.action":
            let decoded = try JSONDecoder().decode(NavigatorActionMessage.self, from: data)
            try decoded.validate()
            response = try runtimeController.perform(navigation: decoded, session: session)
        case "session.lifecycle":
            let decoded = try JSONDecoder().decode(SessionLifecycleMessage.self, from: data)
            try decoded.validate()
            response = try runtimeController.perform(lifecycle: decoded, session: session)
        default:
            return RuntimeStatus.invalidMessage
        }
    } catch is ActionMessageError {
        return RuntimeStatus.invalidMessage
    } catch is LifecycleMessageError {
        return RuntimeStatus.invalidMessage
    } catch RuntimeControllerError.invalidSession {
        return RuntimeStatus.invalidMessage
    } catch {
        return RuntimeStatus.processingFailed
    }
    return writeJSON(response, to: output, length: outputLength)
}

private let releaseCallback: ReleaseCall = { _, bytes, _ in bytes?.deallocate() }
private let destroyCallback: DestroyCall = { _ in
    runtimeControlLock.lock()
    defer { runtimeControlLock.unlock() }
    runtimeController.shutdown()
}

// 宿主按 runtime 串行调用 ABI；统一锁避免不同入口并发破坏会话状态。
private let runtimeControlLock = NSRecursiveLock()
private let runtimeController = EBookRuntimeController()

nonisolated(unsafe) private let interfacePointer: UnsafeMutablePointer<RuntimeInterfaceV1> = {
    let pointer = UnsafeMutablePointer<RuntimeInterfaceV1>.allocate(capacity: 1)
    pointer.initialize(to: RuntimeInterfaceV1(
        apiVersion: 1,
        structSize: MemoryLayout<RuntimeInterfaceV1>.size,
        context: nil,
        createSession: createSessionCallback,
        performCommand: performCommandCallback,
        releaseBytes: releaseCallback,
        destroy: destroyCallback,
        performApplicationCommand: nil
    ))
    return pointer
}()

@_cdecl("foofoil_extension_create")
public func foofoilExtensionCreate(_ negotiatedAPIVersion: UInt32) -> UnsafeRawPointer? {
    guard negotiatedAPIVersion == 1 else { return nil }
    return UnsafeRawPointer(interfacePointer)
}

private func jsonObject(_ input: UnsafePointer<UInt8>?, length: Int) -> [String: Any]? {
    guard let input, length > 0,
          let value = try? JSONSerialization.jsonObject(with: Data(bytes: input, count: length)) else {
        return nil
    }
    return value as? [String: Any]
}

private func writeJSON(
    _ object: [String: Any],
    to output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    length outputLength: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let output, let outputLength,
          let data = try? JSONSerialization.data(withJSONObject: object) else {
        return RuntimeStatus.processingFailed
    }
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    data.copyBytes(to: bytes, count: data.count)
    output.pointee = bytes
    outputLength.pointee = data.count
    return RuntimeStatus.success
}
