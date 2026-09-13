//  EPUBError.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// 解析失败的稳定分类；Runtime 据此映射本地化 key，不把内部错误文本直接展示给用户。
public enum EPUBError: Error, Equatable {
    /// ZIP 结构损坏、截断或使用了不支持的分卷/压缩方法。
    case invalidArchive
    /// container.xml 缺失或无法解析出 rootfile。
    case invalidContainer
    /// OPF 缺失、结构错误或 spine 不可用。
    case invalidPackage
    /// 正文加密或未知加密算法。
    case encrypted
    /// spine 正文媒体类型不受支持。
    case unsupportedContent
    /// 资源/章节超过第 3.7 节限制。
    case limitExceeded
    /// 引用的包内资源不存在或路径非法。
    case missingResource(String)
    /// 章节 XHTML 解析或清理失败。
    case chapterRenderingFailed
}
