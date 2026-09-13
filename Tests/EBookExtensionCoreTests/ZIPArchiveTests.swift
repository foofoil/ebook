//  ZIPArchiveTests.swift
//  EBookExtensionCoreTests
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import EBookTestSupport
import Foundation
import Testing

struct ZIPArchiveTests {
    @Test func readsStoredAndDeflatedEntries() throws {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "stored.txt", text: "hello stored")
        builder.add(name: "deflated.txt", text: String(repeating: "compress me ", count: 200), compress: true)
        let url = try TestFile.write(try builder.build())
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZIPArchive(url: url)
        #expect(archive.entryCount == 2)
        #expect(try archive.data(for: "stored.txt") == Data("hello stored".utf8))
        #expect(try archive.data(for: "deflated.txt") == Data(String(repeating: "compress me ", count: 200).utf8))
    }

    @Test func rejectsCorruptCRC() throws {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "a.txt", text: "abcdef")
        var archiveData = try builder.build()
        guard let range = archiveData.range(of: Data("abcdef".utf8)) else {
            Issue.record("missing payload")
            return
        }
        archiveData[range.lowerBound] = 0x41
        let url = try TestFile.write(archiveData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZIPArchive(url: url)
        #expect(throws: EPUBError.invalidArchive) {
            _ = try archive.data(for: "a.txt")
        }
    }

    @Test func rejectsPathTraversalAndDuplicates() throws {
        var traversal = EPUBFixtureBuilder()
        traversal.add(name: "../evil.txt", text: "x")
        let traversalURL = try TestFile.write(try traversal.build())
        defer { try? FileManager.default.removeItem(at: traversalURL) }
        #expect(throws: EPUBError.invalidArchive) {
            _ = try ZIPArchive(url: traversalURL)
        }

        var duplicate = EPUBFixtureBuilder()
        duplicate.add(name: "a/./b.txt", text: "x")
        let duplicateURL = try TestFile.write(try duplicate.build())
        defer { try? FileManager.default.removeItem(at: duplicateURL) }
        #expect(throws: EPUBError.invalidArchive) {
            _ = try ZIPArchive(url: duplicateURL)
        }
    }

    @Test func rejectsEncryptedAndTruncatedArchives() throws {
        var builder = EPUBFixtureBuilder()
        builder.add(name: "a.txt", text: "abcdef")
        var data = try builder.build()
        let eocd = data.count - 22
        let centralOffset = Int(data.readU32(eocd + 16))
        // 同时打上本地头与中央目录的加密标志位。
        data[6] = data[6] | 0x01
        data[centralOffset + 8] = data[centralOffset + 8] | 0x01
        let encryptedURL = try TestFile.write(data)
        defer { try? FileManager.default.removeItem(at: encryptedURL) }
        #expect(throws: EPUBError.encrypted) {
            _ = try ZIPArchive(url: encryptedURL)
        }

        let truncatedURL = try TestFile.write(data.prefix(10))
        defer { try? FileManager.default.removeItem(at: truncatedURL) }
        #expect(throws: EPUBError.invalidArchive) {
            _ = try ZIPArchive(url: truncatedURL)
        }
    }

    @Test func enforcesEntryOutputLimit() throws {
        var limits = EPUBLimits()
        limits.maxEntryOutputBytes = 4
        var builder = EPUBFixtureBuilder()
        builder.add(name: "big.txt", text: String(repeating: "x", count: 64))
        let url = try TestFile.write(try builder.build())
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZIPArchive(url: url, limits: limits)
        #expect(throws: EPUBError.limitExceeded) {
            _ = try archive.data(for: "big.txt")
        }
    }
}
