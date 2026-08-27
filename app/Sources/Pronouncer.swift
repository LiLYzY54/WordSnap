import AVFoundation

/// 朗读查词结果：有道 dictvoice 美音。
/// 关键在「预取」——查词成功后立刻后台下载进缓存，用户点击时基本已在
/// 本地，AVAudioPlayer 直接播，不再经历「点击才开始下载」的漫长等待。
@MainActor
final class Pronouncer {

    static let shared = Pronouncer()

    private var player: AVAudioPlayer?
    private static let audioCache = NSCache<NSString, NSData>()

    private init() {
        Self.audioCache.countLimit = 50
    }

    /// 查词成功后调用：后台拉取音频（失败静默，不占用用户等待）。
    func prefetch(_ word: String) {
        Task {
            _ = await Self.fetchAudio(word)
        }
    }

    func play(_ word: String) {
        Task { [weak self] in
            guard let self, let data = await Self.fetchAudio(word) else { return }
            await MainActor.run {
                self.player = try? AVAudioPlayer(data: data)
                self.player?.prepareToPlay()
                self.player?.play()
            }
        }
    }

    private nonisolated static func fetchAudio(_ word: String) async -> Data? {
        if let cached = audioCache.object(forKey: word as NSString) {
            return cached as Data
        }
        let query = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        guard let url = URL(string: "https://dict.youdao.com/dictvoice?type=2&audio=\(query)") else {
            return nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        audioCache.setObject(data as NSData, forKey: word as NSString)
        return data
    }
}
