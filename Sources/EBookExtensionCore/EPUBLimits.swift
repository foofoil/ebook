//  EPUBLimits.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// v1 资源与大小上限。所有分配或写盘前检查，测试可注入更小值。
public struct EPUBLimits: Sendable {
    /// 输入 EPUB 文件上限。
    public var maxFileBytes: UInt64
    /// ZIP entry 数与中央目录字节数。
    public var maxEntryCount: Int
    public var maxCentralDirectoryBytes: Int
    /// 单个 entry 实际解压输出。
    public var maxEntryOutputBytes: Int
    /// 单个 XML 文档的节点数与元素深度（解析前预检）。
    public var maxXMLNodeCount: Int
    public var maxXMLDepth: Int
    /// 单章累计资源解压量 / 最终 HTML UTF-8。
    public var maxChapterResourceBytes: Int
    public var maxChapterHTMLBytes: Int
    /// 单个会话已缓存 HTML 总量。
    public var maxCachedHTMLBytes: Int
    /// 全部 navigator 节点（含 spine 分组）/ 树深 / 单标题字符数。
    public var maxNavigatorItems: Int
    public var maxNavigatorDepth: Int
    public var maxNavigatorTitleCharacters: Int
    /// 扩展完整会话 JSON 预算。
    public var maxSessionJSONBytes: Int

    public init(
        maxFileBytes: UInt64 = 1 << 30,
        maxEntryCount: Int = 50_000,
        maxCentralDirectoryBytes: Int = 32 << 20,
        maxEntryOutputBytes: Int = 32 << 20,
        maxXMLNodeCount: Int = 100_000,
        maxXMLDepth: Int = 128,
        maxChapterResourceBytes: Int = 64 << 20,
        maxChapterHTMLBytes: Int = 32 << 20,
        maxCachedHTMLBytes: Int = 256 << 20,
        maxNavigatorItems: Int = 2_000,
        maxNavigatorDepth: Int = 32,
        maxNavigatorTitleCharacters: Int = 256,
        maxSessionJSONBytes: Int = 512 << 10
    ) {
        self.maxFileBytes = maxFileBytes
        self.maxEntryCount = maxEntryCount
        self.maxCentralDirectoryBytes = maxCentralDirectoryBytes
        self.maxEntryOutputBytes = maxEntryOutputBytes
        self.maxXMLNodeCount = maxXMLNodeCount
        self.maxXMLDepth = maxXMLDepth
        self.maxChapterResourceBytes = maxChapterResourceBytes
        self.maxChapterHTMLBytes = maxChapterHTMLBytes
        self.maxCachedHTMLBytes = maxCachedHTMLBytes
        self.maxNavigatorItems = maxNavigatorItems
        self.maxNavigatorDepth = maxNavigatorDepth
        self.maxNavigatorTitleCharacters = maxNavigatorTitleCharacters
        self.maxSessionJSONBytes = maxSessionJSONBytes
    }

    public static let `default` = EPUBLimits()
}
