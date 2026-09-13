//  HTMLEntities.swift
//  EBookExtensionCore
//
//  Created by 董超 on 2026/9/13.
//

import Foundation

/// XHTML 中常见命名实体的数字替换。XML 内建实体同样归一化为数字引用，
/// 未知命名实体明确失败，避免把未清理标记带进渲染器。
enum HTMLEntities {
    static func preprocess(_ text: String) throws -> String {
        var result = String()
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let searchStart = text.index(after: index)
            var cursor = searchStart
            var name = ""
            while cursor < text.endIndex, name.count <= 32 {
                let current = text[cursor]
                if current == ";" { break }
                if current.isWhitespace || current == "&" || current == "<" { break }
                name.append(current)
                cursor = text.index(after: cursor)
            }
            if cursor < text.endIndex, text[cursor] == ";", !name.isEmpty {
                if name.hasPrefix("#") {
                    result.append(contentsOf: text[index ... cursor])
                } else if let value = named[name] {
                    result.append("&#\(value);")
                } else {
                    throw EPUBError.chapterRenderingFailed
                }
                index = text.index(after: cursor)
            } else {
                result.append("&amp;")
                index = searchStart
            }
        }
        return result
    }

    static let named: [String: UInt32] = [
        "quot": 34, "amp": 38, "apos": 39, "lt": 60, "gt": 62,
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164,
        "yen": 165, "brvbar": 166, "sect": 167, "uml": 168, "copy": 169,
        "ordf": 170, "laquo": 171, "not": 172, "shy": 173, "reg": 174,
        "macr": 175, "deg": 176, "plusmn": 177, "sup2": 178, "sup3": 179,
        "acute": 180, "micro": 181, "para": 182, "middot": 183, "cedil": 184,
        "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189,
        "frac34": 190, "iquest": 191,
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196,
        "Aring": 197, "AElig": 198, "Ccedil": 199, "Egrave": 200, "Eacute": 201,
        "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205, "Icirc": 206,
        "Iuml": 207, "ETH": 208, "Ntilde": 209, "Ograve": 210, "Oacute": 211,
        "Ocirc": 212, "Otilde": 213, "Ouml": 214, "times": 215, "Oslash": 216,
        "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221,
        "THORN": 222, "szlig": 223,
        "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228,
        "aring": 229, "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233,
        "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237, "icirc": 238,
        "iuml": 239, "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243,
        "ocirc": 244, "otilde": 245, "ouml": 246, "divide": 247, "oslash": 248,
        "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253,
        "thorn": 254, "yuml": 255,
        "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376,
        "fnof": 402, "circ": 710, "tilde": 732,
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205,
        "lrm": 8206, "rlm": 8207, "ndash": 8211, "mdash": 8212, "horbar": 8213,
        "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221,
        "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226,
        "hellip": 8230, "permil": 8240, "prime": 8242, "Prime": 8243,
        "lsaquo": 8249, "rsaquo": 8250, "oline": 8254, "frasl": 8260,
        "euro": 8364, "trade": 8482, "minus": 8722, "lowast": 8727,
        "radic": 8730, "infin": 8734, "ne": 8800, "le": 8804, "ge": 8805,
        "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596,
        "spades": 9824, "clubs": 9827, "hearts": 9829, "diams": 9830,
        "lceil": 8968, "rceil": 8969, "lfloor": 8970, "rfloor": 8971,
        "loz": 9674, "lang": 9001, "rang": 9002, "sum": 8721, "prod": 8719,
        "dash": 8208, "sdote": 10854, "star": 9734, "starf": 9733,
        "check": 10003, "cross": 10007, "sext": 10038,
        "flat": 9837, "natural": 9838, "sharp": 9839
    ]
}
