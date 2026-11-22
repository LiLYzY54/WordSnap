#!/usr/bin/env swift
// 一次性迁移：旧 7 列表格 -> 新格式
//   旧: | 单词 | 音标 | 词性 | 释义 | 英文原意 | 例句 | 备注 |
//   新: | 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
// 去重（按单词，保留首条）、清理 HTML 标签，保留表格外的正文。
// 用法: swift migrate_vocab.swift <file> [--dry-run]

import Foundation

func cleanHTML(_ s: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

enum MigrationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

// A pipe separates columns only outside a wikilink and when it is not escaped.
func tableCells(_ line: String) throws -> [String] {
    let characters = Array(line.trimmingCharacters(in: .whitespacesAndNewlines))
    var cells: [String] = []
    var cell = ""
    var inLink = false
    var index = 0
    while index < characters.count {
        let character = characters[index]
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        if character == "\\", let next, next == "|" || next == "\\" {
            cell.append(next)
            index += 2
            continue
        }
        if character == "[", next == "[" {
            inLink = true
            cell += "[["
            index += 2
            continue
        }
        if character == "]", next == "]" {
            inLink = false
            cell += "]]"
            index += 2
            continue
        }
        if character == "|", !inLink {
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            cell = ""
        } else {
            cell.append(character)
        }
        index += 1
    }
    cells.append(cell.trimmingCharacters(in: .whitespaces))
    guard !inLink, cells.count >= 3, cells.first == "", cells.last == "" else {
        throw MigrationError.invalid("表格行格式不完整，已停止迁移：\(line)")
    }
    return Array(cells.dropFirst().dropLast())
}

func migrate(_ raw: String) throws -> (content: String, count: Int)? {
    let oldHeader = ["单词", "音标", "词性", "释义", "英文原意", "例句", "备注"]
    let newHeader = ["单词", "音标", "词性", "释义", "例句", "来源", "日期"]
    var lines = raw.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("|") }) else {
        throw MigrationError.invalid("未找到词汇表，原文件未修改")
    }
    let header = try tableCells(lines[start])
    if header == newHeader { return nil }
    guard header == oldHeader || header == oldHeader + ["日期"] else {
        throw MigrationError.invalid("无法识别旧词汇表表头，原文件未修改")
    }
    guard lines.indices.contains(start + 1) else {
        throw MigrationError.invalid("词汇表缺少分隔行，原文件未修改")
    }
    let separator = try tableCells(lines[start + 1])
    guard separator.count == header.count,
          separator.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else {
        throw MigrationError.invalid("词汇表分隔行无效，原文件未修改")
    }

    var seen = Set<String>()
    var rows: [[String]] = []
    var end = start + 2
    for index in (start + 2)..<lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        guard line.hasPrefix("|") else { break }
        let cells = try tableCells(line)
        guard cells.count == header.count else {
            throw MigrationError.invalid("第 \(index + 1) 行列数与表头不符，原文件未修改")
        }
        end = index + 1
        var word = cells[0]
        if word.hasPrefix("[["), word.hasSuffix("]]") {
            word = String(word.dropFirst(2).dropLast(2))
            if let alias = word.firstIndex(of: "|") { word = String(word[..<alias]) }
        }
        word = word.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else {
            throw MigrationError.invalid("第 \(index + 1) 行单词为空，原文件未修改")
        }
        guard seen.insert(word.lowercased()).inserted else { continue }
        rows.append([word, cleanHTML(cells[1]), cleanHTML(cells[2]), cleanHTML(cells[3]),
                     cleanHTML(cells[5]), cleanHTML(cells[6]),
                     header.count == 8 ? cleanHTML(cells[7]) : ""])
    }
    func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }
    var output = ["| " + newHeader.joined(separator: " | ") + " |",
                  "|------|------|------|------|------|------|------|"]
    output += rows.map { "| " + $0.map(escape).joined(separator: " | ") + " |" }
    lines.replaceSubrange(start..<end, with: output)
    return (lines.joined(separator: "\n"), rows.count)
}

func main() throws {
    let args = CommandLine.arguments
    guard args.count == 2 || (args.count == 3 && args[2] == "--dry-run") else {
        throw MigrationError.invalid("用法: swift migrate_vocab.swift <markdown-file> [--dry-run]")
    }
    let path = args[1]
    let dryRun = args.contains("--dry-run")

    let raw = try String(contentsOfFile: path, encoding: .utf8)
    guard let result = try migrate(raw) else {
        print("已是新格式，无需迁移（原文件未修改）")
        return
    }
    if dryRun {
        print("== 迁移预览（\(result.count) 个词，原文件不动）==")
        print(result.content)
    } else {
        let bak = path + ".bak"
        guard !FileManager.default.fileExists(atPath: bak) else {
            throw MigrationError.invalid("备份已存在，请先保管好 \(bak)；原文件未修改")
        }
        try FileManager.default.copyItem(atPath: path, toPath: bak)
        try result.content.write(toFile: path, atomically: true, encoding: .utf8)
        print("已迁移 \(result.count) 个词 -> \(path)（备份: \(bak)）")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("迁移失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
