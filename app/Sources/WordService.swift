import Foundation
import Network

// MARK: - Model

/// A dictionary entry ready to be displayed and saved to Obsidian.
struct WordEntry: Codable, Equatable {
    var word: String
    var phonetic: String
    var partOfSpeech: String
    var meaning: String
    var englishDef: String
    var example: String
    var source: String
    /// yyyy-MM-dd
    var date: String
}

// MARK: - Errors

enum LookupError: LocalizedError {
    case network(String)
    case badResponse
    case notFound

    var errorDescription: String? {
        switch self {
        case .network: return "网络不稳定，请检查代理或稍后重试"
        case .badResponse: return "词典接口返回异常"
        case .notFound: return "未找到该单词"
        }
    }
}

// MARK: - Service

/// Looks up words via the Youdao Dictionary JSON API and persists entries
/// to the Obsidian vocabulary table. Pure Swift — no external processes.
final class WordService {

    static let shared = WordService()

    /// Target Obsidian note. Resolution order:
    /// 1. WORDSNAP_OBSIDIAN_PATH env var
    /// 2. ~/.wordsnap.json { "obsidianPath": "..." }
    /// 3. generic default
    static let obsidianFile: String = {
        if let override = ProcessInfo.processInfo.environment["WORDSNAP_OBSIDIAN_PATH"],
           !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wordsnap.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = json["obsidianPath"] as? String, !path.isEmpty {
            return NSString(string: path).expandingTildeInPath
        }
        return NSString(
            string: "~/Documents/Obsidian/English Vocabulary Learning.md"
        ).expandingTildeInPath
    }()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    // MARK: Lookup

    func lookup(_ rawWord: String) async throws -> WordEntry {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw LookupError.notFound }

        let start = Date()

        // 快路径：绕过代理的持久直连（IP 记忆 + 连接复用）
        do {
            let data = try await YoudaoDirectClient.shared.lookup(word)
            let entry = try Self.parse(data, word: word)
            Self.logTiming(word: word, ms: Date().timeIntervalSince(start) * 1000, via: "direct")
            return entry
        } catch {
            // 慢路径兑底：走系统代理的 URLSession（限时）
            do {
                let data = try await proxyFetch(word)
                let entry = try Self.parse(data, word: word)
                Self.logTiming(word: word, ms: Date().timeIntervalSince(start) * 1000, via: "proxy")
                return entry
            } catch {
                Self.logTiming(word: word, ms: Date().timeIntervalSince(start) * 1000, via: "failed")
                throw LookupError.network("网络不稳定，请检查代理或稍后重试")
            }
        }
    }

    private static func logTiming(word: String, ms: Double, via: String) {
        NSLog("WordSnap [lookup] %@ via %@: %.0f ms", word, via, ms)
    }

    /// Fallback through the system proxy (URLSession), single attempt, 1.5s cap.
    private func proxyFetch(_ word: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var components = URLComponents(string: "https://dict.youdao.com/jsonapi")!
        components.queryItems = [URLQueryItem(name: "q", value: word)]
        var request = URLRequest(url: components.url!)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LookupError.badResponse
        }
        return data
    }

    // MARK: - 直连客户端（绕过代理，持久连接）

    /// Connects straight to Youdao's real IP with TLS SNI pinned to
    /// dict.youdao.com — immune to TUN fake-IP DNS. Reuses one connection
    /// (HTTP/1.1 keep-alive) so repeat lookups skip DNS + TLS handshake.
    final class YoudaoDirectClient {

        static let shared = YoudaoDirectClient()

        private let host = "dict.youdao.com"
        private let queue = DispatchQueue(label: "com.wordsnap.youdao", qos: .userInitiated)
        private var connection: NWConnection?
        private var connectionIP: String?

        private static let seedIPs = ["220.197.31.37", "123.58.167.197", "220.197.27.26"]

        private static var ipList: [String] {
            get {
                let saved = UserDefaults.standard.stringArray(forKey: "youdaoDirectIPs")
                return (saved?.isEmpty == false) ? saved! : seedIPs
            }
            set { UserDefaults.standard.set(newValue, forKey: "youdaoDirectIPs") }
        }

        /// Try IPs in order (best remembered first); reuse the live connection.
        func lookup(_ word: String) async throws -> Data {
            let ips = Self.ipList
            var lastError: Error = LookupError.network("直连失败")
            for ip in ips {
                do {
                    let data = try await request(word: word, ip: ip)
                    Self.promote(ip)
                    return data
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }

        /// Open the persistent connection ahead of time so the first real
        /// lookup hits a live TLS pipe instead of paying connect latency.
        func warmUp() {
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                if self.connection == nil {
                    let ip = Self.ipList.first ?? Self.seedIPs[0]
                    self.connection = try? await self.openConnection(ip: ip)
                    if self.connection != nil { self.connectionIP = ip }
                }
            }
        }

        private func request(word: String, ip: String) async throws -> Data {
            // 连接不匹配或已断：重建
            if connection == nil || connectionIP != ip {
                connection?.cancel()
                connection = try await openConnection(ip: ip)
                connectionIP = ip
            }
            guard let conn = connection else { throw LookupError.network("直连失败") }

            let query = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
            let request = "GET /jsonapi?q=\(query) HTTP/1.1\r\n"
                + "Host: \(host)\r\n"
                + "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n"
                + "Accept: */*\r\n"
                + "Connection: keep-alive\r\n\r\n"

            do {
                return try await sendAndRead(conn, request: request)
            } catch {
                // 连接坏了：丢弃，下次重连
                connection?.cancel()
                connection = nil
                connectionIP = nil
                throw error
            }
        }

        private func openConnection(ip: String) async throws -> NWConnection {
            guard let address = IPv4Address(ip) else { throw LookupError.network("无效 IP") }
            let tlsOptions = NWProtocolTLS.Options()
            if let name = (host as NSString).utf8String {
                sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, name)
            }
            let conn = NWConnection(host: .ipv4(address), port: 443, using: NWParameters(tls: tlsOptions))

            return try await withCheckedThrowingContinuation { continuation in
                var done = false
                func resume(_ result: Result<NWConnection, Error>) {
                    guard !done else { return }
                    done = true
                    continuation.resume(with: result)
                }
                let timer = DispatchWorkItem { resume(.failure(URLError(.timedOut))) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: timer)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        timer.cancel()
                        resume(.success(conn))
                    case .failed(let error):
                        timer.cancel()
                        resume(.failure(error))
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
            }
        }

        /// Send one HTTP/1.1 request and read the framed response body.
        private func sendAndRead(_ conn: NWConnection, request: String) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                var done = false
                func resume(_ result: Result<Data, Error>) {
                    guard !done else { return }
                    done = true
                    continuation.resume(with: result)
                }
                let deadline = DispatchWorkItem { resume(.failure(URLError(.timedOut))) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: deadline)

                conn.send(content: request.data(using: .utf8), completion: .contentProcessed { error in
                    if let error {
                        deadline.cancel()
                        resume(.failure(error))
                    } else {
                        readHeaders(buffer: Data())
                    }
                })

                func readHeaders(buffer: Data) {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        if let error {
                            deadline.cancel()
                            resume(.failure(error))
                            return
                        }
                        var buf = buffer
                        if let data { buf.append(data) }
                        guard let text = String(data: buf, encoding: .utf8),
                              let headerEnd = text.range(of: "\r\n\r\n") else {
                            if complete || buf.count > 128 * 1024 {
                                deadline.cancel()
                                resume(.failure(LookupError.badResponse))
                            } else {
                                readHeaders(buffer: buf)
                            }
                            return
                        }
                        let header = String(text[..<headerEnd.lowerBound])
                        var body = Data(text[headerEnd.upperBound...].utf8)
                        let contentLength = Self.contentLength(in: header)
                        if let contentLength, contentLength > 0 {
                            readBody(body: body, remaining: contentLength - body.count)
                        } else if header.lowercased().contains("connection: close") {
                            readToEOF(body: body)
                        } else {
                            deadline.cancel()
                            resume(.success(body))
                        }

                        func readBody(body: Data, remaining: Int) {
                            guard remaining > 0 else {
                                deadline.cancel()
                                resume(.success(body))
                                return
                            }
                            conn.receive(minimumIncompleteLength: min(remaining, 64 * 1024), maximumLength: 64 * 1024) { data, _, complete, error in
                                if let error {
                                    deadline.cancel()
                                    resume(.failure(error))
                                    return
                                }
                                var newBody = body
                                let received = data?.count ?? 0
                                if let data { newBody.append(data) }
                                if complete && received < remaining {
                                    deadline.cancel()
                                    resume(.failure(LookupError.badResponse))
                                } else {
                                    readBody(body: newBody, remaining: remaining - received)
                                }
                            }
                        }

                        func readToEOF(body: Data) {
                            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                                if let error {
                                    deadline.cancel()
                                    resume(.failure(error))
                                    return
                                }
                                var newBody = body
                                if let data { newBody.append(data) }
                                if complete {
                                    deadline.cancel()
                                    resume(.success(newBody))
                                } else {
                                    readToEOF(body: newBody)
                                }
                            }
                        }
                    }
                }
            }
        }

        private static func contentLength(in header: String) -> Int? {
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    return Int(parts[1])
                }
            }
            return nil
        }

        /// Move the last successful IP to the front so next lookup hits it first.
        private static func promote(_ ip: String) {
            var list = ipList
            if let index = list.firstIndex(of: ip) { list.remove(at: index) }
            list.insert(ip, at: 0)
            ipList = list
        }
    }

    // MARK: Parsing

    private struct YoudaoResponse: Decodable {
        struct Simple: Decodable {
            struct WordInfo: Decodable { var usphone: String? }
            struct Custom: Decodable { var v: String? }

            var word: [WordInfo]?
            var custom: [Custom]?
        }

        struct Ec: Decodable {
            // 实际结构: trs[i].tr[j].l.i[k] -> "adj. 短暂的；…"
            struct Line: Decodable { var i: [String]? }
            struct Item: Decodable { var l: Line? }
            struct Trs: Decodable { var tr: [Item]? }
            struct WordInfo: Decodable {
                var trs: [Trs]?
            }
            var word: [WordInfo]?
        }

        struct Collins: Decodable {
            struct EntryGroup: Decodable {
                struct Inner: Decodable {
                    struct PosEntry: Decodable {
                        var pos: String?
                        var pos_tips: String?
                    }
                    struct TranEntry: Decodable {
                        var tran: String?
                        var pos_entry: PosEntry?
                    }
                    var tran_entry: [TranEntry]?
                }
                var entry: [Inner]?
            }
            struct Entry: Decodable {
                var entries: EntryGroup?
            }
            var collins_entries: [Entry]?
        }

        struct Blng: Decodable {
            struct Pair: Decodable { var sentence: String? }
            var sentencePair: [Pair]?

            enum CodingKeys: String, CodingKey {
                case sentencePair = "sentence-pair"
            }
        }

        var simple: Simple?
        var ec: Ec?
        var collins: Collins?
        var blng_sents_part: Blng?
    }

    private static func parse(_ data: Data, word: String) throws -> WordEntry {
        let decoded: YoudaoResponse
        do {
            decoded = try JSONDecoder().decode(YoudaoResponse.self, from: data)
        } catch {
            throw LookupError.badResponse
        }

        // 音标
        let phonetic = decoded.simple?.word?.first?.usphone ?? ""

        // 词性 + 释义（柯林斯优先，ec 词典兑底）
        var partOfSpeech = ""
        var meaning = ""
        var englishDef = ""
        if let tran = decoded.collins?.collins_entries?.first?.entries?.entry?.first?.tran_entry?.first {
            partOfSpeech = cleanHTML(tran.pos_entry?.pos_tips ?? "")
            if partOfSpeech.isEmpty {
                partOfSpeech = cleanHTML(tran.pos_entry?.pos ?? "")
            }
            // 柯林斯格式为「英文解释 + 中文翻译」，拆开分别入表
            (englishDef, meaning) = splitEnglishChinese(cleanHTML(tran.tran ?? ""))
        } else {
            let translations = (decoded.ec?.word?.first?.trs ?? [])
                .compactMap { $0.tr?.first?.l?.i }
                .flatMap { $0 }
                .map { cleanHTML($0) }
                .filter { !$0.isEmpty }
            meaning = translations.joined(separator: "; ")
        }
        // 兜底：simple.custom
        if meaning.isEmpty {
            meaning = cleanHTML(decoded.simple?.custom?.first?.v ?? "")
        }

        guard !meaning.isEmpty else { throw LookupError.notFound }

        // 例句
        let example = cleanHTML(decoded.blng_sents_part?.sentencePair?.first?.sentence ?? "")

        return WordEntry(
            word: word,
            phonetic: phonetic,
            partOfSpeech: partOfSpeech,
            meaning: meaning,
            englishDef: englishDef,
            example: example,
            source: "Youdao",
            date: Self.dateFormatter.string(from: Date())
        )
    }

    /// Split a Collins definition like
    /// "If you describe something as ephemeral, ... 短暂的; 瞬间的"
    /// into (englishDef, chineseMeaning).
    private static func splitEnglishChinese(_ text: String) -> (english: String, chinese: String) {
        guard let firstCJK = text.firstIndex(where: { isCJK($0) }) else {
            return ("", text)
        }
        let english = String(text[text.startIndex..<firstCJK]).trimmingCharacters(in: .whitespaces)
        let chinese = String(text[firstCJK...]).trimmingCharacters(in: .whitespaces)
        return (english, chinese)
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func cleanHTML(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: Save

    /// Append the entry as a Markdown table row. Read–modify–write atomically,
    /// creating the file (with header) when missing and never leaving stray
    /// blank lines. Skips words that are already in the table (dedupe).
    func save(_ entry: WordEntry) throws -> Bool {
        let path = Self.obsidianFile
        let directory = NSString(string: path).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var content: String
        if FileManager.default.fileExists(atPath: path),
           let existing = try? String(contentsOfFile: path, encoding: .utf8),
           !existing.isEmpty {
            content = existing
            if !content.hasSuffix("\n") { content += "\n" }

            // Dedupe: check the 单词 column (first cell) of existing rows only.
            if Self.containsWord(entry.word, in: content) {
                return false
            }
        } else {
            content = Self.tableHeader + "\n"
        }
        content += Self.markdownRow(for: entry)

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }

    /// True if any markdown table row in `content` has `word` as its first cell
    /// (matching both plain and [[link]] forms).
    private static func containsWord(_ word: String, in content: String) -> Bool {
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }
            let cells = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard cells.count >= 2 else { continue }
            var first = cells[1].trimmingCharacters(in: .whitespaces)
            // [[word|word]] -> word
            if let inner = first.range(of: "[[") { first = String(first[inner.upperBound...]) }
            first = first.replacingOccurrences(of: "]]", with: "")
            if let pipe = first.firstIndex(of: "|") { first = String(first[..<pipe]) }
            first = first.trimmingCharacters(in: .whitespaces)
            if first == word { return true }
        }
        return false
    }

    private static let tableHeader = """
    | 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
    |------|------|------|------|------|------|------|
    """

    private static func markdownRow(for entry: WordEntry) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var phonetic = entry.phonetic
        if !phonetic.isEmpty && !phonetic.hasPrefix("/") {
            phonetic = "/\(phonetic)/"
        }
        // 单词列用 Obsidian 双链，自动关联/创建词条笔记
        let linked = "[[\(entry.word)|\(entry.word)]]"
        return "| \(linked) | \(escape(phonetic)) | \(escape(entry.partOfSpeech)) | "
             + "\(escape(entry.meaning)) | \(escape(entry.example)) | \(escape(entry.source)) | \(escape(entry.date)) |\n"
    }
}
