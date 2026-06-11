import Foundation
import AVFoundation

// MARK: - Voice catalogue

struct KokoroVoice: Identifiable {
    let id: String
    let displayName: String
    let grade: String   // "A", "A−", "B−", "C+", "C"
}

let kokoroVoices: [KokoroVoice] = [
    // ── Grade A ──────────────────────────────────────────────────────────────
    KokoroVoice(id: "af_heart",   displayName: "Heart",   grade: "A"),
    KokoroVoice(id: "af_bella",   displayName: "Bella",   grade: "A−"),
    // ── Grade B ──────────────────────────────────────────────────────────────
    KokoroVoice(id: "af_nicole",  displayName: "Nicole",  grade: "B−"),
    KokoroVoice(id: "bf_emma",    displayName: "Emma",    grade: "B−"),
    // ── Grade C+ ─────────────────────────────────────────────────────────────
    KokoroVoice(id: "af_sarah",   displayName: "Sarah",   grade: "C+"),
    KokoroVoice(id: "af_aoede",   displayName: "Aoede",   grade: "C+"),
    KokoroVoice(id: "af_kore",    displayName: "Kore",    grade: "C+"),
    KokoroVoice(id: "am_fenrir",  displayName: "Fenrir",  grade: "C+"),
    KokoroVoice(id: "am_michael", displayName: "Michael", grade: "C+"),
    KokoroVoice(id: "am_puck",    displayName: "Puck",    grade: "C+"),
    // ── Grade C ──────────────────────────────────────────────────────────────
    KokoroVoice(id: "af_nova",    displayName: "Nova",    grade: "C"),
    KokoroVoice(id: "bm_george",  displayName: "George",  grade: "C"),
    KokoroVoice(id: "bm_fable",   displayName: "Fable",   grade: "C"),
]

// MARK: - Markdown stripping (free function — no actor isolation, directly testable)

func kokoroStripMarkdown(_ text: String) -> String {
    var s = text
    s = s.replacingOccurrences(of: "```[\\s\\S]*?```",        with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "`[^`]+`",                 with: "",   options: .regularExpression)
    s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*",         with: "",   options: .regularExpression)
    s = s.replacingOccurrences(of: "(?m)^[-*_]{3,}$",         with: "",   options: .regularExpression)
    s = s.replacingOccurrences(of: "\\*{1,3}([^*]+)\\*{1,3}", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "_{1,3}([^_]+)_{1,3}",     with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "[^\\S\\n]+",               with: " ",  options: .regularExpression)
    s = s.replacingOccurrences(of: "\\n{3,}",                  with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - KokoroBridge
//
// Drives a persistent Python subprocess running the Kokoro TTS daemon.
// Requests and responses are JSON lines over stdin/stdout.
// The pipeline keeps the model in memory between calls — first call ~3-5 s
// (model + voice download), subsequent calls near-instant.

@MainActor
final class KokoroBridge: NSObject, ObservableObject, AVAudioPlayerDelegate {

    // MARK: Published state

    @Published var isReady    = false
    @Published var isLoading  = false
    @Published var isSpeaking = false
    @Published var isPaused   = false
    @Published var loadError: String? = nil

    static let defaultVoice = "af_heart"

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

    func loadModel() {
        guard process == nil else {
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
            .appendingPathComponent("pendragon_kokoro_daemon.py")
        do {
            try Self.daemonScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            loadError = "Could not write TTS daemon: \(error.localizedDescription)"
            isLoading = false
            return
        }

        guard let python = Self.findPython3() else {
            loadError = "python3 not found — install Python 3.11 with kokoro (pip install kokoro)."
            isLoading = false
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments     = [scriptURL.path]

        let i = Pipe(), o = Pipe(), e = Pipe()
        p.standardInput  = i
        p.standardOutput = o
        p.standardError  = e

        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                self.inPipe  = nil
                self.outPipe = nil
                self.isReady = false
                for (_, cont) in self.pending {
                    cont.resume(throwing: NSError(domain: "KokoroBridge", code: 99,
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

        // Pre-warm the Kokoro pipeline in the background so it's ready before
        // the first synthesis request. Model load takes ~5-10 s on first run.
        Task {
            _ = try? await send(["id": UUID().uuidString, "cmd": "warmup"])
        }
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
            cont.resume(throwing: NSError(domain: "KokoroBridge", code: 0,
                userInfo: [NSLocalizedDescriptionKey: msg]))
        }
    }

    private func send(_ json: [String: Any]) async throws -> String {
        guard let pipe = inPipe else {
            throw NSError(domain: "KokoroBridge", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Daemon not running"])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "KokoroBridge", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "JSON encode failed"])
        }
        let id = json["id"] as! String
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            pipe.fileHandleForWriting.write((line + "\n").data(using: .utf8)!)
        }
    }

    // MARK: Synthesis

    func synthesizeToData(text: String, voice: String, speed: Float) async -> Data? {
        if process == nil { loadModel() }
        let clean = Self.stripMarkdown(text)
        guard !clean.isEmpty else { return nil }

        let id  = UUID().uuidString
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptts_\(id)").path

        let req: [String: Any] = [
            "id":     id,
            "cmd":    "generate",
            "voice":  voice,
            "text":   clean,
            "speed":  Double(speed),
            "output": tmp + ".wav"
        ]

        do {
            let path = try await send(req)
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: tmp + ".wav")
            return data
        } catch {
            print("[KokoroBridge] \(error.localizedDescription)")
            return nil
        }
    }

    func speak(text: String, voice: String, speed: Float) {
        stopSpeaking()
        Task {
            if let d = await synthesizeToData(text: text, voice: voice, speed: speed) {
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
            player     = p
            isSpeaking = true
        } catch {
            print("[KokoroBridge] AVAudioPlayer: \(error)")
        }
    }

    func stopSpeaking() {
        player?.stop()
        player     = nil
        isSpeaking = false
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

    var availableVoices: [KokoroVoice] { kokoroVoices }

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

    nonisolated static func stripMarkdown(_ text: String) -> String {
        kokoroStripMarkdown(text)
    }

    // MARK: - Embedded daemon script

    private static let daemonScript = #"""
    import sys, json, os
    from pathlib import Path

    # Must be set before kokoro/misaki import so the espeakng dylib finds its data.
    import espeakng_loader
    os.environ['ESPEAK_DATA_PATH'] = espeakng_loader.get_data_path()

    SAMPLE_RATE = 24000
    _pipeline   = None

    def get_pipeline():
        global _pipeline
        if _pipeline is None:
            from kokoro import KPipeline
            _pipeline = KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')
        return _pipeline

    def do_generate(req):
        import numpy as np
        import soundfile as sf

        output = req.get("output", "")
        text   = req.get("text", "").strip()
        if not text:
            return {"ok": False, "error": "empty text"}

        voice = req.get("voice", "af_heart")
        speed = float(req.get("speed", 1.0))

        out_dir = Path(output)
        out_dir.mkdir(parents=True, exist_ok=True)
        out_wav = str(out_dir / "audio.wav")

        pipeline  = get_pipeline()
        all_audio = []
        for result in pipeline(text, voice=voice, speed=speed):
            if result.audio is not None:
                all_audio.append(result.audio.numpy())

        if not all_audio:
            return {"ok": False, "error": "no audio generated"}

        audio = np.concatenate(all_audio)
        sf.write(out_wav, audio, SAMPLE_RATE)
        return {"ok": True, "path": out_wav}

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
                if cmd == "ping" or cmd == "warmup":
                    get_pipeline()
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
