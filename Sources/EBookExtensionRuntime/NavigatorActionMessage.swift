//  NavigatorActionMessage.swift
//  EBookExtensionRuntime
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// 与 extension-kit 的 ui.navigator.action v1 JSON 对应；不依赖宿主 Swift 类型。
struct NavigatorActionMessage: Decodable {
    struct Action: Decodable {
        enum Kind: String, Decodable { case activate, move, remove }
        enum Position: String, Decodable { case before, after, end }
        let contributionID: String
        let kind: Kind
        let itemIDs: [String]
        let destinationItemID: String?
        let movePosition: Position?
    }

    let commandID: String
    let contractVersion: UInt32
    let action: Action

    func validate() throws {
        guard commandID == "ui.navigator.action", contractVersion == 1 else {
            throw ActionMessageError.invalidMessage
        }
        guard action.contributionID == "ebook.toc",
              action.kind == .activate,
              action.itemIDs.count == 1,
              action.destinationItemID == nil,
              action.movePosition == nil else {
            throw ActionMessageError.invalidAction
        }
    }
}

enum ActionMessageError: Error {
    case invalidMessage
    case invalidAction
}
