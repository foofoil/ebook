//  main.swift
//  EBookInspect
//
//  Created by 董超 on 2026/9/13.
//

import EBookExtensionCore
import Foundation

private func usage() -> Never {
    FileHandle.standardError.write(Data(
        "Usage: ebook-inspect <file.epub> [--chapter <zero-based-index>]\n".utf8
    ))
    exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }
let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
var chapterIndex: Int?
if arguments.count >= 4, arguments[2] == "--chapter" {
    chapterIndex = Int(arguments[3])
}

do {
    let document = try EPUBDocument(url: url)
    print("title: \(document.title ?? "-")")
    print("creators: \(document.creators.joined(separator: ", "))")
    print("language: \(document.language ?? "-")")
    print("chapters: \(document.chapters.count)")
    print("toc nodes: \(countNodes(document.toc))")
    for chapter in document.chapters {
        print("  [\(chapter.index)]\(chapter.linear ? "" : " (non-linear)") \(chapter.title)")
    }
    print("toc:")
    printTree(document.toc, indent: 1)
    if let chapterIndex {
        let html = try document.renderChapter(at: chapterIndex)
        print("chapter \(chapterIndex) html bytes: \(html.utf8.count)")
    }
} catch {
    FileHandle.standardError.write(Data("ebook-inspect failed: \(error)\n".utf8))
    exit(1)
}

private func countNodes(_ entries: [EPUBTOCEntry]) -> Int {
    entries.reduce(0) { $0 + 1 + countNodes($1.children) }
}

private func printTree(_ entries: [EPUBTOCEntry], indent: Int) {
    for entry in entries {
        let location = entry.path.map { $0 + (entry.fragment.map { "#\($0)" } ?? "") } ?? "(no link)"
        print(String(repeating: "  ", count: indent) + "- \(entry.title) -> \(location)")
        printTree(entry.children, indent: indent + 1)
    }
}
