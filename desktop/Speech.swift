// Live speech for Ask Lavi answers: ElevenLabs Eleven v4 Turbo in Lavi's voice, played as it streams in.
// The API key lives only in your login Keychain (you paste it into Settings); it is never written to disk.
import AVFoundation
import Foundation
import Security

let laviVoiceID = "HCx2PwbeGgmrPl8yw3w0"

enum Keychain {
    static let service = "com.chadkraus.codebuddy.elevenlabs"
    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult static func set(_ key: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        var add = base; add[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum Speech {
    /// Speaks `text` in Lavi's voice through `player` as it streams in (Eleven v4 Turbo over the Text to Dialogue
    /// websocket, so the first sound comes in well under a second). `done` gets nil once all the audio has arrived,
    /// or a plain-language reason it couldn't.
    static func stream(_ text: String, into player: StreamPlayer, done: @escaping (SpeechError?) -> Void) {
        guard let key = Keychain.get() else { return done(SpeechError(message: "add your ElevenLabs API key in Lavi's settings to hear answers.")) }
        var req = URLRequest(url: URL(string: "wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input?model_id=eleven_v4_turbo&output_format=pcm_24000")!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let task = URLSession.shared.webSocketTask(with: req)
        var finished = false
        func finish(_ err: SpeechError?) {
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                task.cancel(with: .normalClosure, reason: nil)
                player.end()
                done(err)
            }
        }
        player.cancel = { task.cancel(with: .normalClosure, reason: nil) }
        func send(_ obj: [String: Any]) {
            let json = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
            task.send(.string(json)) { if let e = $0 { finish(failure(task, e)) } }
        }
        func receive() {
            task.receive { result in
                switch result {
                case .failure(let e): finish(failure(task, e))
                case .success(let msg):
                    guard case .string(let s) = msg, let m = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return receive() }
                    let type = m["message_type"] as? String ?? ""
                    if m["error"] != nil || type.contains("error") {
                        let why = (m["message"] ?? m["error"]).map { "\($0)" } ?? "unknown error"
                        return finish(SpeechError(message: why.lowercased().contains("auth") || why.contains("api_key") || why.contains("API key")
                            ? "ElevenLabs didn't accept the API key. check it in Lavi's settings."
                            : "ElevenLabs couldn't read it out (\(why.prefix(120)))."))
                    }
                    if let b64 = m["audio"] as? String, let pcm = Data(base64Encoded: b64) {
                        DispatchQueue.main.async { player.append(pcm) }
                    }
                    if m["is_final"] as? Bool == true || m["isFinal"] as? Bool == true || type.hasSuffix("websocket_final") { return finish(nil) }
                    receive()
                }
            }
        }
        task.resume()
        send(["voices": [laviVoiceID]])
        send(["inputs": [["text": String(text.prefix(800)), "voice_id": laviVoiceID]]])
        send(["close_socket": true])
        receive()
        // Nothing at all after 30 s: give up rather than leave the bubble hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if !player.started { finish(SpeechError(message: "ElevenLabs didn't answer in time. try again in a bit.")) } }
    }

    private static func failure(_ task: URLSessionWebSocketTask, _ e: Error) -> SpeechError {
        if (task.response as? HTTPURLResponse)?.statusCode == 401 { return SpeechError(message: "ElevenLabs didn't accept the API key. check it in Lavi's settings.") }
        return SpeechError(message: "couldn't reach ElevenLabs right now (\(e.localizedDescription)).")
    }
}

/// Plays 16-bit 24 kHz mono PCM as it arrives, and knows how loud it is right now (for the mouth). Main thread only.
final class StreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var carry = Data()      // an odd byte left over from a chunk that split a sample
    private var levels: [Float] = [] // loudness per 50 ms of audio, in play order
    private var queued = 0, ended = false, stopped = false
    private(set) var started = false
    private(set) var seconds: Double = 0
    var onFinish: (() -> Void)?
    var cancel: (() -> Void)?
    var volume: Float { get { node.volume } set { node.volume = newValue } }

    init?(volume: Float) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = volume
        do { try engine.start() } catch { return nil }
    }

    var isPlaying: Bool { started && !stopped && (queued > 0 || !ended) }

    func append(_ data: Data) {
        guard !stopped else { return }
        var bytes = carry + data
        carry = bytes.count % 2 == 1 ? bytes.suffix(1) : Data()
        if !carry.isEmpty { bytes.removeLast() }
        let n = bytes.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        bytes.withUnsafeBytes { raw in
            for i in 0..<n { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        for w in stride(from: 0, to: n, by: 1200) { // 50 ms windows
            let end = min(w + 1200, n)
            var sum: Float = 0
            for i in w..<end { sum += out[i] * out[i] }
            let db = 10 * log10(max(sum / Float(end - w), 1e-9))
            levels.append(max(0, min(1, (db + 40) / 40)))
        }
        seconds += Double(n) / 24000
        queued += 1
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.queued -= 1; self.checkDone() }
        }
        // ponytail: starts on the first chunk; if the network ever fell behind playback, the mouth would drift a little.
        if !started { started = true; node.play() }
    }

    /// No more audio is coming.
    func end() { ended = true; checkDone() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        cancel?()
        node.stop(); engine.stop()
    }

    /// Loudness 0…1 of what's playing right now.
    func level() -> Float {
        guard isPlaying, let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return 0 }
        let i = Int(Double(p.sampleTime) / p.sampleRate * 20)
        return levels.indices.contains(i) ? levels[i] : 0
    }

    /// Seconds of audio not yet played.
    var remaining: Double {
        guard let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return seconds }
        return max(0, seconds - Double(p.sampleTime) / p.sampleRate)
    }

    private func checkDone() {
        guard ended, queued == 0, !stopped else { return }
        stop()
        onFinish?()
    }
}

struct SpeechError: Error { let message: String }
