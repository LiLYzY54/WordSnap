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
    /// 柯林斯星级（"1"..."5"），无则 nil
    var star: String?
}

// MARK: - Errors

enum LookupError: LocalizedError {
    case network(String)
    case badResponse
    case notFound

    var errorDescription: String? {
        switch self {
        case .network: return "网络连接失败，请检查网络后重试"
        case .badResponse: return "词典接口返回异常"
        case .notFound: return "未找到该单词"
        }
    }
}

// MARK: - Chunked 传输解码（纯逻辑，无 IO，单测覆盖）

/// RFC 7230 §4.1 增量解码器。把每次收到的新数据 feed 进来，
/// 凑满终止块（0-chunk）并消费完 trailer 段后，一次性返回完整正文。
/// trailer 段被完整吃掉是 keep-alive 复用正确性的前提——否则残留
/// 字节会错位到下一个响应的头部。
struct ChunkDecoder {

    enum Outcome: Equatable {
        case needMore
        case completed(Data)
        case invalid
    }

    private var payload = Data()
    private var buffer = Data()
    /// 0-chunk 之后进入 trailer 阶段：逐行丢弃直到空行结束
    private var readingTrailers = false

    mutating func feed(_ data: Data) -> Outcome {
        buffer.append(data)
        while true {
            guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
                return .needMore
            }
            if readingTrailers {
                let isEmptyLine = lineEnd.lowerBound == buffer.startIndex
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                if isEmptyLine { return .completed(payload) }
                continue
            }

            let sizeLineData = buffer.subdata(in: buffer.startIndex..<lineEnd.lowerBound)
            let sizeLine = String(data: sizeLineData, encoding: .utf8) ?? ""
            // 大小行允许 chunk 扩展："5;name=value" → 5
            let hexText = sizeLine.split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(hexText, radix: 16), size >= 0 else {
                return .invalid
            }

            if size == 0 {
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                readingTrailers = true
                continue
            }

            let chunkStart = lineEnd.upperBound
            let required = size + 2 // 正文 + 结尾 CRLF
            if buffer.endIndex - chunkStart < required {
                return .needMore
            }
            payload.append(contentsOf: buffer[chunkStart..<(chunkStart + size)])
            buffer.removeSubrange(buffer.startIndex..<(chunkStart + required))
        }
    }
}

// MARK: - Save outcome

/// 保存结果：横幅文案所需的一切。
struct SaveOutcome {
    /// false = 词已存在（重逢，未写入新行）
    let saved: Bool
    /// 词表当前总词数
    let totalCount: Int
    /// 连续保存天数（含今天）
    let streakDays: Int
    /// 重逢时：该词原保存日期 yyyy-MM-dd
    let existingDate: String?
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

        // 快路径：绕过代理的持久直连（IP 记忆 + 连接复用）。
        // 拿到完整响应后如果查无此词，直接上抛 notFound——拼错的词不是
        // 网络问题，不能再触发代理兜底，否则会被误报成「网络不稳定」。
        var directData: Data?
        do {
            directData = try await YoudaoDirectClient.shared.lookup(word)
        } catch {
            NSLog("WordSnap [direct] failed for %@: %@", word, String(describing: error))
        }

        if let data = directData {
            do {
                let entry = try Self.parse(data, word: word)
                Self.logTiming(word: word, ms: Date().timeIntervalSince(start) * 1000, via: "direct")
                return entry
            } catch LookupError.notFound {
                Self.logTiming(word: word, ms: Date().timeIntervalSince(start) * 1000, via: "direct:not-found")
                throw LookupError.notFound
            } catch {
                // 响应解析失败（接口格式变化等）：降级走代理再试一次
            }
        }

        // 慢路径兑底：走系统代理的 URLSession（限时）
        do {
            let data = try await proxyFetch(word)
            let entry = try Self.parse(data, word: word)
            Self.logTiming(word: word, ms: Date().timeIntervalSince(start) * 1000, via: "proxy")
            return entry
        } catch {
            Self.logTiming(word: word, ms: Date().timeIntervalSince(start) * 1000, via: "failed")
            throw LookupError.network("网络连接失败，请检查网络后重试")
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
    ///
    /// actor 隔离：connection/connectionIP 只在 actor 内串行访问。
    /// 此前的裸 class 里，warmUp 的后台任务和主线程的快速连查会同时
    /// 读写 connection、各自开连接互相覆盖——教科书式 data race。
    actor YoudaoDirectClient {

        static let shared = YoudaoDirectClient()

        private let host = "dict.youdao.com"
        /// NWConnection 的全部回调都落在同一条串行队列上，
        /// continuation 的 done 标记因此天然原子，无需额外加锁。
        private let queue = DispatchQueue(label: "com.wordsnap.youdao", qos: .userInitiated)
        private var connection: NWConnection?
        private var connectionIP: String?

        private static let seedIPs = ["220.197.31.37", "123.58.167.197", "220.197.27.26"]
        private static let maxIPs = 8
        private static let ipListKey = "youdaoDirectIPs"
        private static let refreshedAtKey = "youdaoDirectIPsRefreshedAt"
        private static let refreshInterval: TimeInterval = 24 * 60 * 60

        private static var ipList: [String] {
            get {
                let saved = UserDefaults.standard.stringArray(forKey: ipListKey)
                return (saved?.isEmpty == false) ? saved! : seedIPs
            }
            set { UserDefaults.standard.set(newValue, forKey: ipListKey) }
        }

        /// Try IPs in order (best remembered first); reuse the live connection.
        func lookup(_ word: String) async throws -> Data {
            scheduleRefreshIfStale()
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
        /// （shared 是进程级单例，闭包强持有无害；勿加捕获列表——
        ///   Swift 5 检查级别下显式捕获会让 Task 失去 actor 隔离推断。）
        func warmUp() {
            scheduleRefreshIfStale()
            guard connection == nil else { return }
            let ip = Self.ipList.first ?? Self.seedIPs[0]
            Task {
                self.connection = try? await self.openConnection(ip: ip)
                if self.connection != nil { self.connectionIP = ip }
            }
        }

        // MARK: IP 池学习

        /// 种子 IP 是写死的：CDN 一换地址，所有用户的每次查询都要先串行
        /// 吃满整个过期列表的连接超时。这里隔天用真实 DNS 解析刷新一次池子，
        /// 顺序为「学习到的成功 IP → 新解析结果 → 种子垫底」，且只在超过
        /// 刷新间隔时触发一次后台任务，不阻塞当前查询。
        private func scheduleRefreshIfStale() {
            let now = Date().timeIntervalSince1970
            guard now - UserDefaults.standard.double(forKey: Self.refreshedAtKey)
                    > Self.refreshInterval else { return }
            UserDefaults.standard.set(now, forKey: Self.refreshedAtKey)
            Task.detached(priority: .utility) { [weak self] in
                let resolved = Self.resolveIPv4(host: "dict.youdao.com")
                await self?.merge(resolved: resolved)
            }
        }

        private func merge(resolved fresh: [String]) {
            guard !fresh.isEmpty else { return }
            var seen = Set<String>()
            var merged: [String] = []
            func push(_ ip: String) {
                if !ip.isEmpty && !seen.contains(ip) {
                    seen.insert(ip)
                    merged.append(ip)
                }
            }
            Self.ipList.filter { !Self.seedIPs.contains($0) }.forEach(push)
            fresh.forEach(push)
            Self.seedIPs.forEach(push)
            Self.ipList = Array(merged.prefix(Self.maxIPs))
        }

        /// 真实 DNS 解析（getaddrinfo），绕开 TUN fake-IP 拿到可达的服务器地址。
        /// 阻塞式调用，只应在 utility 队列执行。
        private nonisolated static func resolveIPv4(host name: String) -> [String] {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, nil, &hints, &info) == 0, info != nil else { return [] }
            defer { freeaddrinfo(info) }

            var out: [String] = []
            var node: UnsafeMutablePointer<addrinfo>? = info
            while let current = node {
                if current.pointee.ai_family == AF_INET,
                   let sockaddrPtr = current.pointee.ai_addr {
                    let sin = sockaddrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var addr = sin.sin_addr
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        out.append(String(cString: buf))
                    }
                }
                node = current.pointee.ai_next
            }
            return out
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

        /// Body 分帧决策依据 RFC 7230：chunked 存在时优先于 Content-Length。
        private enum BodyFraming {
            case length(Int)
            case chunked
            /// connection: close 且无分帧头 → 读到连接关闭为止
            case untilClose
            /// keep-alive 但没有分帧头（非标准响应）：沿用旧实现的宽容做法，
            /// 头包里已到达的字节即视为正文，避免在复用连接上读到 4s 超时。
            case unframedKeepAlive
        }

        private static let headerSeparator = Data("\r\n\r\n".utf8)
        private static let maxBodyBytes = 4 * 1024 * 1024

        /// Send one HTTP/1.1 request and read the framed response body.
        /// 非 2xx 状态码直接拒绝（badResponse 会驱动上层走代理兜底），
        /// 而不是像旧实现那样把 403 的 HTML 页当成 JSON 去 decode。
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

                func succeed(_ data: Data) {
                    deadline.cancel()
                    resume(.success(data))
                }
                func fail(_ error: Error) {
                    deadline.cancel()
                    resume(.failure(error))
                }

                var buffer = Data()
                var framing: BodyFraming?
                var chunker = ChunkDecoder()

                /// true 表示该结果已终结本次读取
                func settle(_ outcome: ChunkDecoder.Outcome) -> Bool {
                    switch outcome {
                    case .completed(let payload):
                        succeed(payload)
                        return true
                    case .invalid:
                        fail(LookupError.badResponse)
                        return true
                    case .needMore:
                        return false
                    }
                }

                func pump() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        if let error { fail(error); return }
                        if let data { buffer.append(data) }

                        if framing == nil {
                            guard let separator = buffer.range(of: Self.headerSeparator) else {
                                if complete || buffer.count > 256 * 1024 {
                                    fail(LookupError.badResponse)
                                } else {
                                    pump()
                                }
                                return
                            }
                            guard let headerText = String(
                                    data: buffer.subdata(in: buffer.startIndex..<separator.lowerBound),
                                    encoding: .utf8
                                ),
                                let status = Self.statusCode(in: headerText),
                                (200..<300).contains(status) else {
                                fail(LookupError.badResponse)
                                return
                            }
                            framing = Self.framing(in: headerText)
                            // 头部之后余下的字节就是正文开头（可能同包到达）
                            let body = buffer.subdata(in: separator.upperBound..<buffer.endIndex)
                            buffer.removeAll(keepingCapacity: true)

                            switch framing! {
                            case .unframedKeepAlive:
                                succeed(body)
                                return
                            case .chunked:
                                if settle(chunker.feed(body)) { return }
                                pump()
                                return
                            case .length, .untilClose:
                                buffer = body
                            }
                        }

                        switch framing! {
                        case .unframedKeepAlive:
                            pump() // 不可达，防御性兜底
                        case .length(let total):
                            if buffer.count >= total {
                                succeed(Data(buffer.prefix(total)))
                            } else if complete && buffer.count < total {
                                fail(LookupError.badResponse)
                            } else if buffer.count > Self.maxBodyBytes {
                                fail(LookupError.badResponse)
                            } else {
                                pump()
                            }
                        case .chunked:
                            if settle(chunker.feed(data ?? Data())) { return }
                            pump()
                        case .untilClose:
                            if complete {
                                succeed(buffer)
                            } else if buffer.count > Self.maxBodyBytes {
                                fail(LookupError.badResponse)
                            } else {
                                pump()
                            }
                        }
                    }
                }

                conn.send(content: request.data(using: .utf8), completion: .contentProcessed { error in
                    if let error {
                        fail(error)
                    } else {
                        pump()
                    }
                })
            }
        }

        /// "HTTP/1.1 200 OK" → 200
        static func statusCode(in header: String) -> Int? {
            let statusLine = header.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let fields = statusLine.split(separator: " ").map(String.init)
            guard fields.count >= 2, fields[0].hasPrefix("HTTP/") else { return nil }
            return Int(fields[1].trimmingCharacters(in: .whitespaces))
        }

        private static func framing(in header: String) -> BodyFraming {
            var isChunked = false
            var contentLength: Int?
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let name = parts[0].lowercased()
                let value = parts[1].lowercased()
                if name == "transfer-encoding", value.contains("chunked") { isChunked = true }
                if name == "content-length" { contentLength = Int(value) }
            }
            if isChunked { return .chunked }
            if let contentLength, contentLength >= 0 { return .length(contentLength) }
            let closes = header.lowercased().contains("connection: close")
            return closes ? .untilClose : .unframedKeepAlive
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
                    /// 柯林斯核心词星级，"1"..."5"
                    var star: String?
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

    /// 有道响应 → 词表条目。格式变化时抛 badResponse；
    /// 响应有效但查无释义时抛 notFound。
    static func parse(_ data: Data, word: String) throws -> WordEntry {
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
        var star: String?
        if let inner = decoded.collins?.collins_entries?.first?.entries?.entry?.first {
            star = inner.star
            let tran = inner.tran_entry?.first
            partOfSpeech = cleanHTML(tran?.pos_entry?.pos_tips ?? "")
            if partOfSpeech.isEmpty {
                partOfSpeech = cleanHTML(tran?.pos_entry?.pos ?? "")
            }
            // 柯林斯格式为「英文解释 + 中文翻译」，拆开分别入表
            (englishDef, meaning) = splitEnglishChinese(cleanHTML(tran?.tran ?? ""))
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
            date: Self.dateFormatter.string(from: Date()),
            star: star
        )
    }

    /// Split a Collins definition like
    /// "If you describe something as ephemeral, ... 短暂的; 瞬间的"
    /// into (englishDef, chineseMeaning).
    static func splitEnglishChinese(_ text: String) -> (english: String, chinese: String) {
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
    func save(_ entry: WordEntry) throws -> SaveOutcome {
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
                let stats = Self.stats(in: content)
                return SaveOutcome(saved: false, totalCount: stats.total,
                                   streakDays: stats.streakDays,
                                   existingDate: Self.existingRowDate(entry.word, in: content))
            }
        } else {
            content = Self.tableHeader + "\n"
        }
        content += Self.markdownRow(for: entry)

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let stats = Self.stats(in: content)
        return SaveOutcome(saved: true, totalCount: stats.total,
                           streakDays: stats.streakDays, existingDate: nil)
    }

    // MARK: Table parsing (供统计/重逢/陪伴类功能共用的行解析)

    /// 表格数据行的单元格列表；跳过表头与分隔行。
    /// 首列=单词（可能带 [[链接]]），末列=日期。
    static func tableRows(in content: String) -> [[String]] {
        content.split(separator: "\n").compactMap { line -> [String]? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            guard cells.count >= 7, cells[0] != "单词", !cells[0].contains("--") else { return nil }
            return cells
        }
    }

    /// 统计：总词数 + 连续保存天数（从 on 当天往前数，断档即停）。
    static func stats(in content: String, on date: Date = Date()) -> (total: Int, streakDays: Int) {
        let rows = tableRows(in: content)
        let dates = Set(rows.compactMap { $0.count >= 7 ? $0[6] : nil })
        let calendar = Calendar.current
        var day = date
        var streak = 0
        while dates.contains(dateFormatter.string(from: day)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return (rows.count, streak)
    }

    /// [[word|alias]] → word（不改变大小写）
    static func displayWord(_ raw: String) -> String {
        var first = raw
        if let inner = first.range(of: "[[") { first = String(first[inner.upperBound...]) }
        first = first.replacingOccurrences(of: "]]", with: "")
        if let pipe = first.firstIndex(of: "|") { first = String(first[..<pipe]) }
        return first.trimmingCharacters(in: .whitespaces)
    }

    /// 该词已存在行的原保存日期（重逢提示用）。
    static func existingRowDate(_ word: String, in content: String) -> String? {
        let target = word.lowercased()
        for cells in tableRows(in: content) {
            if displayWord(cells[0]).lowercased() == target, cells.count >= 7 {
                return cells[6]
            }
        }
        return nil
    }

    /// 撤销最近一次保存：移除该词最后一行（去重保证唯一）。文件不存在则忽略。
    @discardableResult
    func deleteRow(word: String) -> Bool {
        let path = Self.obsidianFile
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var lines = content.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return false }
            let first = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().first.map(String.init) ?? ""
            return Self.displayWord(first).lowercased() == word.lowercased()
        }) else { return false }
        lines.remove(at: index)
        let out = lines.joined(separator: "\n")
        return (try? out.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// True if any markdown table row in `content` has `word` as its first cell
    /// (matching both plain and [[link]] forms). Case-insensitive——与迁移脚本
    /// 的去重口径一致，「Word」和「word」不能在表里存两份。
    static func containsWord(_ word: String, in content: String) -> Bool {
        let target = word.lowercased()
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
            if first.lowercased() == target { return true }
        }
        return false
    }

    private static let tableHeader = """
    | 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
    |------|------|------|------|------|------|------|
    """

    static func markdownRow(for entry: WordEntry) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var phonetic = entry.phonetic
        if !phonetic.isEmpty && !phonetic.hasPrefix("/") {
            phonetic = "/\(phonetic)/"
        }
        // 单词列用 Obsidian 双链自动关联/创建词条笔记。
        // 不写 [[word|alias]] 别名形式——别名分隔符是未转义的裸竖线，
        // 在严格 GFM 解析器里会把表格行拦腰截断；显示文本与链接目标
        // 本就相同，别名毫无信息量。
        let linked = "[[\(entry.word)]]"
        return "| \(linked) | \(escape(phonetic)) | \(escape(entry.partOfSpeech)) | "
             + "\(escape(entry.meaning)) | \(escape(entry.example)) | \(escape(entry.source)) | \(escape(entry.date)) |\n"
    }
}
