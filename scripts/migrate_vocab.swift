#!/usr/bin/env swift
// 一次性迁移：旧 7 列表格 -> 新格式
//   旧: | 单词 | 音标 | 词性 | 释义 | 英文原意 | 例句 | 备注 |
//   新: | 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
// 去重（按单词，保留首条）、清理 HTML 标签、去掉空行。
// 用法: swift migrate_vocab.swift <file> [--dry-run]

import Foundation

func cleanHTML(_ s: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func main() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        print("用法: swift migrate_vocab.swift <markdown-file> [--dry-run]")
        exit(1)
    }
    let path = args[1]
    let dryRun = args.contains("--dry-run")

    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("无法读取文件: \(path)")
        exit(1)
    }

    var seen = Set<String>()
    var rows: [[String]] = []
    var headerFound = false

    for line in raw.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.hasSuffix("|") else { continue }
        // 跳过表头/分隔行
        if t.contains("---") { headerFound = true; continue }
        guard headerFound else { continue }

        var cells = t.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        if let first = cells.first, first.isEmpty { cells.removeFirst() }
        if let last = cells.last, last.isEmpty { cells.removeLast() }
        guard cells.count >= 6 else { continue }

        // 单词列可能是 [[word|word]] 或纯文本
        var word = cells[0]
        if let r = word.range(of: "[[") { word = String(word[r.upperBound...]) }
        if let r = word.range(of: "|") { word = String(word[..<r.lowerBound]) }
        word = word.replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { continue }
        if seen.contains(word.lowercased()) { continue }
        seen.insert(word.lowercased())

        // 新列: 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期
        let phonetic = cleanHTML(cells.indices.contains(1) ? cells[1] : "")
        let pos      = cleanHTML(cells.indices.contains(2) ? cells[2] : "")
        let meaning  = cleanHTML(cells.indices.contains(3) ? cells[3] : "")
        let example  = cleanHTML(cells.indices.contains(5) ? cells[5] : (cells.indices.contains(4) ? cells[4] : ""))
        let source   = cells.indices.contains(6) ? cleanHTML(cells[6]) : "Youdao"
        let date     = cells.indices.contains(7) ? cleanHTML(cells[7]) : ""

        rows.append([word, phonetic, pos, meaning, example, source, date])
    }

    let header = "| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |\n|------|------|------|------|------|------|------|"
    var out = header
    for r in rows {
        func esc(_ v: String) -> String { v.replacingOccurrences(of: "|", with: "\\|") }
        out += "\n| \(esc(r[0])) | \(esc(r[1])) | \(esc(r[2])) | \(esc(r[3])) | \(esc(r[4])) | \(esc(r[5])) | \(esc(r[6])) |"
    }

    if dryRun {
        print("== 迁移预览（\(rows.count) 个词，原文件不动）==")
        print(out)
    } else {
        let bak = path + ".bak"
        try? FileManager.default.removeItem(atPath: bak)
        try? FileManager.default.copyItem(atPath: path, toPath: bak)
        try! out.write(toFile: path, atomically: true, encoding: .utf8)
        print("已迁移 \(rows.count) 个词 -> \(path)（备份: \(bak)）")
    }
}

main()
