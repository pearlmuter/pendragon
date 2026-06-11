import Foundation
import AVFoundation

// MARK: - Qwen3 model enum

enum Qwen3Model: String, CaseIterable {
    case customVoice      = "customvoice"        // 1.7B
    case customVoiceSmall = "customvoice_small"  // 0.6B — same speakers, faster
    case voiceDesign      = "voicedesign"        // 1.7B

    var displayName: String {
        switch self {
        case .customVoice:      return "Custom Voice"
        case .customVoiceSmall: return "Custom Voice"
        case .voiceDesign:      return "Voice Design"
        }
    }

    var subtitle: String {
        switch self {
        case .customVoice:      return "9 speakers · full quality (1.7B)"
        case .customVoiceSmall: return "9 speakers · faster, lighter (0.6B)"
        case .voiceDesign:      return "Design any voice from a description"
        }
    }

    var modelId: String {
        switch self {
        case .customVoice:      return "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
        case .customVoiceSmall: return "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
        case .voiceDesign:      return "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
        }
    }

    var isCustomVoice: Bool { self != .voiceDesign }
}

struct Qwen3Voice: Identifiable {
    let id: String          // key sent to model (model lowercases it for lookup)
    let displayName: String
}

let qwen3Voices: [Qwen3Voice] = [
    Qwen3Voice(id: "vivian",    displayName: "Vivian"),
    Qwen3Voice(id: "ryan",      displayName: "Ryan"),
    Qwen3Voice(id: "serena",    displayName: "Serena"),
    Qwen3Voice(id: "aiden",     displayName: "Aiden"),
    Qwen3Voice(id: "uncle_fu",  displayName: "Uncle Fu"),
    Qwen3Voice(id: "ono_anna",  displayName: "Ono Anna"),
    Qwen3Voice(id: "sohee",     displayName: "Sohee"),
    Qwen3Voice(id: "eric",      displayName: "Eric"),
    Qwen3Voice(id: "dylan",     displayName: "Dylan"),
]

struct Qwen3Language: Identifiable {
    let id: String
    let displayName: String
}

let qwen3Languages: [Qwen3Language] = [
    Qwen3Language(id: "auto",            displayName: "Auto"),
    Qwen3Language(id: "english",         displayName: "English"),
    Qwen3Language(id: "chinese",         displayName: "Chinese"),
    Qwen3Language(id: "japanese",        displayName: "Japanese"),
    Qwen3Language(id: "korean",          displayName: "Korean"),
    Qwen3Language(id: "french",          displayName: "French"),
    Qwen3Language(id: "spanish",         displayName: "Spanish"),
    Qwen3Language(id: "german",          displayName: "German"),
    Qwen3Language(id: "italian",         displayName: "Italian"),
    Qwen3Language(id: "portuguese",      displayName: "Portuguese"),
    Qwen3Language(id: "russian",         displayName: "Russian"),
    Qwen3Language(id: "beijing_dialect", displayName: "Beijing Dialect"),
    Qwen3Language(id: "sichuan_dialect", displayName: "Sichuan Dialect"),
]

// MARK: - Qwen3TTSBridge
//
// Drives a persistent Python subprocess running qwen3_tts_daemon.py via mlx-audio.
// Requests and responses are JSON lines over stdin/stdout.
// The daemon keeps the MLX model in memory between calls — first call ~5-8s, subsequent ~3s.

@MainActor
final class Qwen3TTSBridge: NSObject, ObservableObject, AVAudioPlayerDelegate {

    // MARK: Published state

    @Published var isReady   = false
    @Published var isLoading = false
    @Published var isSpeaking = false
    @Published var isPaused  = false
    @Published var loadError: String? = nil

    static let defaultVoice = "vivian"

    // MARK: Private

    private var process: Process?
    private var inPipe:  Pipe?
    private var outPipe: Pipe?
    private var readBuffer = ""
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var player: AVAudioPlayer?

    // MARK: Init / deinit

    override init() { super.init() }

    deinit { process?.terminate() }

    // MARK: Model loading

    func loadModel(model: Qwen3Model = .customVoice) {
        guard process == nil else {
            // Daemon already running; mark ready immediately
            isLoading = false
            isReady   = true
            return
        }
        isLoading = true
        loadError = nil
        startDaemon()
    }

    private func startDaemon() {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendragon_tts_daemon.py")
        do {
            try Self.daemonScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            loadError = "Could not write TTS daemon: \(error.localizedDescription)"
            isLoading = false
            return
        }

        guard let python = Self.findPython3() else {
            loadError = "python3 not found — install Python 3.11 with mlx-audio (pip install mlx-audio)."
            isLoading = false
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments     = [scriptURL.path]

        let i = Pipe(), o = Pipe(), e = Pipe()
        p.standardInput  = i
        p.standardOutput = o
        p.standardError  = e   // stderr goes to system log via print

        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                self.inPipe  = nil
                self.outPipe = nil
                self.isReady = false
                for (_, cont) in self.pending {
                    cont.resume(throwing: NSError(domain: "Qwen3TTS", code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "Daemon terminated unexpectedly"]))
                }
                self.pending.removeAll()
            }
        }

        do {
            try p.run()
        } catch {
            loadError = "Failed to start TTS daemon: \(error.localizedDescription)"
            isLoading = false
            return
        }

        process = p
        inPipe  = i
        outPipe = o

        o.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.received(str) }
        }

        isLoading = false
        isReady   = true
    }

    // MARK: JSON line protocol

    private func received(_ chunk: String) {
        readBuffer += chunk
        while let nl = readBuffer.firstIndex(of: "\n") {
            let line = String(readBuffer[readBuffer.startIndex..<nl])
                .trimmingCharacters(in: .whitespaces)
            readBuffer = String(readBuffer[readBuffer.index(after: nl)...])
            dispatch(line)
        }
    }

    private func dispatch(_ line: String) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id   = json["id"] as? String,
              let cont = pending.removeValue(forKey: id) else { return }

        if (json["ok"] as? Bool) == true, let path = json["path"] as? String {
            cont.resume(returning: path)
        } else {
            let msg = json["error"] as? String ?? "Unknown TTS error"
            cont.resume(throwing: NSError(domain: "Qwen3TTS", code: 0,
                userInfo: [NSLocalizedDescriptionKey: msg]))
        }
    }

    private func send(_ json: [String: Any]) async throws -> String {
        guard let pipe = inPipe else {
            throw NSError(domain: "Qwen3TTS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Daemon not running"])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Qwen3TTS", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "JSON encode failed"])
        }
        let id = json["id"] as! String
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            pipe.fileHandleForWriting.write((line + "\n").data(using: .utf8)!)
        }
    }

    // MARK: Synthesis

    func synthesizeToData(text: String, voice: String, instruct: String?,
                          model: Qwen3Model, speed: Float,
                          langCode: String = "auto") async -> Data? {
        if process == nil { loadModel(model: model) }
        let clean = Self.stripMarkdown(text)
        guard !clean.isEmpty else { return nil }

        let id  = UUID().uuidString
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptts_\(id)").path  // no .wav — daemon resolves the real path

        var req: [String: Any] = [
            "id":        id,
            "cmd":       "generate",
            "model":     model.rawValue,
            "voice":     voice,
            "text":      clean,
            "speed":     Double(speed),
            "lang_code": langCode,
            "output":    tmp + ".wav"
        ]
        if let instruct, !instruct.isEmpty { req["instruct"] = instruct }

        do {
            let path = try await send(req)
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            // Clean up temp file
            try? FileManager.default.removeItem(atPath: path)
            // Also clean up the possible directory
            try? FileManager.default.removeItem(atPath: tmp + ".wav")
            return data
        } catch {
            print("[Qwen3TTSBridge] \(error.localizedDescription)")
            return nil
        }
    }

    func speak(text: String, voice: String, instruct: String?,
               model: Qwen3Model, speed: Float, langCode: String = "auto") {
        stopSpeaking()
        Task {
            if let d = await synthesizeToData(text: text, voice: voice,
                                              instruct: instruct, model: model,
                                              speed: speed, langCode: langCode) {
                await MainActor.run { self.playWAVData(d) }
            }
        }
    }

    // MARK: Playback

    func playWAVData(_ data: Data) { playWAV(data) }

    private func playWAV(_ data: Data) {
        do {
            let p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player    = p
            isSpeaking = true
        } catch {
            print("[Qwen3TTSBridge] AVAudioPlayer: \(error)")
        }
    }

    func stopSpeaking() {
        player?.stop()
        player     = nil
        isSpeaking  = false
        isPaused   = false
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        player?.pause()
        isPaused = true
    }

    func resume() {
        guard isSpeaking, isPaused else { return }
        player?.play()
        isPaused = false
    }

    func skip(seconds: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration, p.currentTime + seconds))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused   = false
            self.player     = nil
        }
    }

    // MARK: Helpers

    private static func findPython3() -> String? {
        [
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ].first { FileManager.default.fileExists(atPath: $0) }
    }

    var availableVoices: [Qwen3Voice] { qwen3Voices }

    nonisolated static func exportAudio(from wavURL: URL, to outputURL: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let dest = Self._uniqueURL(outputURL)
            return (try? FileManager.default.copyItem(at: wavURL, to: dest)) != nil ? dest : nil
        }.value
    }

    private nonisolated static func _uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir  = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        var i = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            candidate = dir.appendingPathComponent(name)
            i += 1
        }
        return candidate
    }

    static func stripMarkdown(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`[^`]+`",          with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*",  with: "",  options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*{1,3}([^*]+)\\*{1,3}", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "_{1,3}([^_]+)_{1,3}",     with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^[-*_]{3,}$", with: "",  options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+",            with: " ",  options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Embedded daemon script
    // Written to $TMPDIR/pendragon_tts_daemon.py on first launch.

    private static let daemonScript = #"""
    import sys, json, gc
    from pathlib import Path

    MODEL_IDS = {
        "voicedesign":       "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
        "customvoice":       "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
        "customvoice_small": "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
    }

    _gen = None

    def get_gen():
        global _gen
        if _gen is None:
            from mlx_audio.tts.generate import generate_audio
            _gen = generate_audio
        return _gen

    def do_generate(req):
        output = req.get("output", "")
        text   = req.get("text",   "").strip()
        if not text:
            return {"ok": False, "error": "empty text"}

        model_key = req.get("model", "customvoice")
        get_gen()(
            text         = text,
            model        = MODEL_IDS.get(model_key, MODEL_IDS["customvoice"]),
            instruct     = req.get("instruct") or None,
            voice        = req.get("voice", "vivian"),
            speed        = float(req.get("speed", 1.0)),
            lang_code    = req.get("lang_code", "auto"),
            output_path  = output,
            audio_format = "wav",
            join_audio   = True,   # all segments joined into one file
            save         = True,
            play         = False,
            verbose      = False,
        )

        # mlx-audio treats output_path as a directory; with join_audio=True it
        # writes {output}/audio.wav; without it writes {output}/audio_000.wav etc.
        p = Path(output)
        if p.is_dir():
            joined = p / "audio.wav"          # join_audio=True result
            if joined.exists():
                return {"ok": True, "path": str(joined)}
            found = sorted(p.glob("audio_*.wav"))  # fallback: first segment
            if found:
                return {"ok": True, "path": str(found[0])}
        elif p.exists():
            return {"ok": True, "path": str(p)}

        # Last resort: directory variant appended to given path
        parent = p.parent
        stem   = p.name.replace(".wav", "")
        for pat in [f"{stem}*/audio.wav", f"{stem}*/audio_*.wav"]:
            found = sorted(parent.glob(pat))
            if found:
                return {"ok": True, "path": str(found[0])}

        return {"ok": False, "error": "output file not found after generation"}

    def main():
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception as e:
                print(json.dumps({"id": "", "ok": False, "error": str(e)}), flush=True)
                continue

            req_id = req.get("id", "")
            cmd    = req.get("cmd", "generate")
            try:
                if cmd == "ping":
                    result = {"ok": True}
                elif cmd == "generate":
                    result = do_generate(req)
                else:
                    result = {"ok": False, "error": f"unknown cmd: {cmd}"}
            except Exception as e:
                result = {"ok": False, "error": str(e)}

            result["id"] = req_id
            print(json.dumps(result), flush=True)

    if __name__ == "__main__":
        main()
    """#
}
