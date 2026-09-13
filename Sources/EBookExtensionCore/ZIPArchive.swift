//  ZIPArchive.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Compression
import Foundation

/// 只读 ZIP 读取器：解析中央目录，按需解压单个 entry，不整包落盘。
/// 所有 offset/size 在使用前校验，deflate 使用 Compression 的 raw DEFLATE 并核对 CRC。
public struct ZIPArchive {
    public struct Entry: Sendable {
        public let path: String
        public let method: UInt16
        public let flags: UInt16
        public let crc32: UInt32
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
    }

    public let url: URL
    public let entries: [String: Entry]
    public let entryCount: Int

    private let fileHandle: FileHandle
    private let fileSize: UInt64
    private let limits: EPUBLimits

    public init(url: URL, limits: EPUBLimits = .default) throws {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else {
            throw EPUBError.invalidArchive
        }
        guard UInt64(size) <= limits.maxFileBytes else { throw EPUBError.limitExceeded }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw EPUBError.invalidArchive
        }
        self.url = url
        self.fileHandle = handle
        self.fileSize = UInt64(size)
        self.limits = limits
        let directory = try Self.readCentralDirectory(handle: handle, fileSize: UInt64(size), limits: limits)
        self.entries = directory
        self.entryCount = directory.count
    }

    public func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    public func data(for path: String, maxBytes: Int? = nil) throws -> Data {
        guard let entry = entries[path] else { throw EPUBError.missingResource(path) }
        return try data(for: entry, maxBytes: maxBytes)
    }

    public func data(for entry: Entry, maxBytes: Int? = nil) throws -> Data {
        let allowed = min(maxBytes ?? limits.maxEntryOutputBytes, limits.maxEntryOutputBytes)
        guard entry.uncompressedSize <= UInt64(allowed) else { throw EPUBError.limitExceeded }
        let header = try Self.read(handle: fileHandle, offset: entry.localHeaderOffset, count: 30)
        guard header.u32(0) == 0x04034b50 else { throw EPUBError.invalidArchive }
        let nameLength = Int(header.u16(26) ?? 0)
        let extraLength = Int(header.u16(28) ?? 0)
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        guard dataOffset >= entry.localHeaderOffset,
              dataOffset <= fileSize,
              entry.compressedSize <= fileSize - dataOffset else { throw EPUBError.invalidArchive }
        let compressed = try Self.read(handle: fileHandle, offset: dataOffset, count: Int(entry.compressedSize))
        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            output = try Self.inflate(compressed, expectedSize: Int(entry.uncompressedSize), limit: allowed)
        default:
            throw EPUBError.unsupportedContent
        }
        guard output.count == Int(entry.uncompressedSize),
              ZIPCRC32.checksum(output) == entry.crc32 else { throw EPUBError.invalidArchive }
        return output
    }

    // MARK: - 中央目录

    private static func readCentralDirectory(
        handle: FileHandle,
        fileSize: UInt64,
        limits: EPUBLimits
    ) throws -> [String: Entry] {
        let searchSize = min(fileSize, UInt64(22 + 65_535))
        let tail = try read(handle: handle, offset: fileSize - searchSize, count: Int(searchSize))
        guard let eocd = lastIndex(of: 0x06054b50, in: tail), eocd + 22 <= tail.count else {
            throw EPUBError.invalidArchive
        }
        guard tail.u16(eocd + 4) == 0, tail.u16(eocd + 6) == 0 else { throw EPUBError.invalidArchive }
        var entryCount = Int(tail.u16(eocd + 10) ?? 0)
        var directorySize = UInt64(tail.u32(eocd + 12) ?? 0)
        var directoryOffset = UInt64(tail.u32(eocd + 16) ?? 0)

        if entryCount == 0xFFFF || directorySize == 0xFFFFFFFF || directoryOffset == 0xFFFFFFFF {
            guard eocd >= 20, tail.u32(eocd - 20) == 0x07064b50 else { throw EPUBError.invalidArchive }
            let zip64Offset = tail.u64(eocd - 12) ?? 0
            guard zip64Offset <= fileSize, fileSize - zip64Offset >= 56 else { throw EPUBError.invalidArchive }
            let zip64 = try read(handle: handle, offset: zip64Offset, count: 56)
            guard zip64.u32(0) == 0x06064b50 else { throw EPUBError.invalidArchive }
            entryCount = Int(zip64.u64(32) ?? 0)
            directorySize = zip64.u64(40) ?? 0
            directoryOffset = zip64.u64(48) ?? 0
        }

        guard entryCount <= limits.maxEntryCount else { throw EPUBError.limitExceeded }
        guard directorySize <= UInt64(limits.maxCentralDirectoryBytes) else { throw EPUBError.limitExceeded }
        guard directoryOffset <= fileSize, directorySize <= fileSize - directoryOffset else {
            throw EPUBError.invalidArchive
        }
        let directory = try read(handle: handle, offset: directoryOffset, count: Int(directorySize))

        var result: [String: Entry] = [:]
        result.reserveCapacity(entryCount)
        var cursor = 0
        while cursor + 46 <= directory.count {
            guard directory.u32(cursor) == 0x02014b50 else { throw EPUBError.invalidArchive }
            let flags = directory.u16(cursor + 8) ?? 0
            let method = directory.u16(cursor + 10) ?? 0
            let crc = directory.u32(cursor + 16) ?? 0
            var compressedSize = UInt64(directory.u32(cursor + 20) ?? 0)
            var uncompressedSize = UInt64(directory.u32(cursor + 24) ?? 0)
            let nameLength = Int(directory.u16(cursor + 28) ?? 0)
            let extraLength = Int(directory.u16(cursor + 30) ?? 0)
            let commentLength = Int(directory.u16(cursor + 32) ?? 0)
            let diskStart = directory.u16(cursor + 34) ?? 0
            let externalAttributes = directory.u32(cursor + 38) ?? 0
            var localHeaderOffset = UInt64(directory.u32(cursor + 42) ?? 0)
            let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= directory.count else { throw EPUBError.invalidArchive }
            let nameData = directory.subdata(in: cursor + 46 ..< cursor + 46 + nameLength)

            try parseZIP64Extra(
                directory.subdata(in: cursor + 46 + nameLength ..< cursor + 46 + nameLength + extraLength),
                compressedSize: &compressedSize,
                uncompressedSize: &uncompressedSize,
                localHeaderOffset: &localHeaderOffset
            )

            guard flags & 0x0001 == 0 else { throw EPUBError.encrypted }
            guard diskStart == 0 else { throw EPUBError.invalidArchive }
            guard method == 0 || method == 8 else { throw EPUBError.unsupportedContent }
            guard localHeaderOffset < fileSize else { throw EPUBError.invalidArchive }
            guard (externalAttributes >> 16) & 0xF000 != 0xA000 else { throw EPUBError.invalidArchive }
            guard let rawName = String(data: nameData, encoding: .utf8) else { throw EPUBError.invalidArchive }
            let path = try validatedPath(rawName)
            guard result[path] == nil else { throw EPUBError.invalidArchive }
            result[path] = Entry(
                path: path,
                method: method,
                flags: flags,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )
            cursor = end
        }
        guard cursor == directory.count else { throw EPUBError.invalidArchive }
        guard result.count == entryCount else { throw EPUBError.invalidArchive }
        return result
    }

    /// ZIP64 extra（0x0001）按“仅对哨兵值补位”的顺序读取。
    private static func parseZIP64Extra(
        _ extra: Data,
        compressedSize: inout UInt64,
        uncompressedSize: inout UInt64,
        localHeaderOffset: inout UInt64
    ) throws {
        guard compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF else {
            return
        }
        var cursor = 0
        while cursor + 4 <= extra.count {
            let fieldID = extra.u16(cursor) ?? 0
            let fieldSize = Int(extra.u16(cursor + 2) ?? 0)
            guard cursor + 4 + fieldSize <= extra.count else { throw EPUBError.invalidArchive }
            if fieldID == 0x0001 {
                var valueCursor = cursor + 4
                if uncompressedSize == 0xFFFFFFFF {
                    guard valueCursor + 8 <= cursor + 4 + fieldSize,
                          let value = extra.u64(valueCursor) else { throw EPUBError.invalidArchive }
                    uncompressedSize = value
                    valueCursor += 8
                }
                if compressedSize == 0xFFFFFFFF {
                    guard valueCursor + 8 <= cursor + 4 + fieldSize,
                          let value = extra.u64(valueCursor) else { throw EPUBError.invalidArchive }
                    compressedSize = value
                    valueCursor += 8
                }
                if localHeaderOffset == 0xFFFFFFFF {
                    guard valueCursor + 8 <= cursor + 4 + fieldSize,
                          let value = extra.u64(valueCursor) else { throw EPUBError.invalidArchive }
                    localHeaderOffset = value
                }
                return
            }
            cursor += 4 + fieldSize
        }
        throw EPUBError.invalidArchive
    }

    /// 拒绝绝对路径、NUL、反斜杠和任何 `..`／`.` 组件；规范化重复路径由调用方处理。
    static func validatedPath(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.contains("\0"), !raw.hasPrefix("/"), !raw.contains("\\") else {
            throw EPUBError.invalidArchive
        }
        var components: [Substring] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty { continue }
            guard component != ".", component != ".." else { throw EPUBError.invalidArchive }
            components.append(component)
        }
        guard !components.isEmpty else { throw EPUBError.invalidArchive }
        return components.joined(separator: "/")
    }

    // MARK: - 二进制读取

    static func read(handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw EPUBError.invalidArchive }
        if count == 0 { return Data() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw EPUBError.invalidArchive
            }
            return data
        } catch let error as EPUBError {
            throw error
        } catch {
            throw EPUBError.invalidArchive
        }
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 4
        while index >= 0 {
            if data.u32(index) == signature { return index }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ input: Data, expectedSize: Int, limit: Int) throws -> Data {
        guard expectedSize <= limit else { throw EPUBError.limitExceeded }
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let produced = output.withUnsafeMutableBytes { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, expectedSize, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced == expectedSize else { throw EPUBError.invalidArchive }
        return output
    }
}

/// ZIP 使用的标准 CRC-32；测试 ZIP 生成器复用同一实现。
public enum ZIPCRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    func u64(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.littleEndian
    }
}
