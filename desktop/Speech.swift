// Live speech for Ask Lavi answers: ElevenLabs text-to-speech in Lavi's voice.
// The API key lives only in your login Keychain (you paste it into Settings); it is never written to disk.
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
    /// mp3 bytes of `text` spoken in Lavi's voice, or a plain-language reason it couldn't.
    static func synthesize(_ text: String, done: @escaping (Result<Data, SpeechError>) -> Void) {
        guard let key = Keychain.get() else { return done(.failure(SpeechError(message: "add your ElevenLabs API key in Lavi's settings to hear answers."))) }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(laviVoiceID)?output_format=mp3_44100_128")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": String(text.prefix(800)), "model_id": "eleven_v3"])
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if let data, code == 200 { done(.success(data)) }
                else if code == 401 { done(.failure(SpeechError(message: "ElevenLabs didn't accept the API key. check it in Lavi's settings."))) }
                else { done(.failure(SpeechError(message: "couldn't reach ElevenLabs right now (\(err?.localizedDescription ?? "status \(code)")).")))}
            }
        }.resume()
    }
}

struct SpeechError: Error { let message: String }
