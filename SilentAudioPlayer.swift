import AVFoundation

/// 播放一段静音 WAV，目的是让 App 在后台保持音频会话处于激活状态，
/// 画中画 + 后台音频两个条件同时满足时，iOS 才不会挂起 App。
final class SilentAudioPlayer {

    private var player: AVAudioPlayer?

    func start() {
        if let player {
            if !player.isPlaying { player.play() }
            return
        }

        let data = SilentAudioPlayer.makeSilentWAV(seconds: 2, sampleRate: 8000)
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 0.02
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            NSLog("KingFloat: silent audio failed - \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private static func makeSilentWAV(seconds: Int, sampleRate: Int) -> Data {
        let sampleCount = sampleRate * seconds
        let dataSize = sampleCount * 2
        var data = Data(capacity: 44 + dataSize)

        func appendASCII(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }

        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
