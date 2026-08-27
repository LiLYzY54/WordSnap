import AVFoundation

/// 朗读查词结果：有道 dictvoice 美音，AVPlayer 流式播放。
/// 换词即替换 player——连点不叠音。
final class Pronouncer {

    static let shared = Pronouncer()

    private var player: AVPlayer?

    func play(_ word: String) {
        let query = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        guard let url = URL(string: "https://dict.youdao.com/dictvoice?type=2&audio=\(query)") else { return }
        player = AVPlayer(url: url)
        player?.play()
    }
}
