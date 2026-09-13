//  TestSupport.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

enum TestFile {
    static func write(_ data: Data, pathExtension: String = "epub") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}

extension Data {
    func readU16(_ offset: Int) -> UInt16 {
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }

    func readU32(_ offset: Int) -> UInt32 {
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }
}
