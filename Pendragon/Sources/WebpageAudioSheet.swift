import SwiftUI
import AppKit

// MARK: - WebpageAudioSheet

struct WebpageAudioSheet: View {
    @ObservedObject var ttsEngine: TTSEngine
    @Binding var isPresented: Bool

    enum Phase: Equatable {
        case idle
        case fetching
        case extracting
        case synthesizing
        case ready
        case failed(String)
    }

    @State private var urlText       = ""
    @State private var phase: Phase  = .idle
    @State private var article: Article?
    @State private var audioData: Data?
    @State private var fetchTask:  Task<Void, Never>?
    @State private var synthTask:  Task<Void, Never>?
    @State private var player: NSSound?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 14) {
                urlRow
                if let a = article { articleCard(a) }
                phaseRow
                if case .failed(let msg) = phase { errorRow(msg) }
            }
            .padding(20)
            if audioData != nil {
                Divider().opacity(0.4)
                playbackBar
            }
        }
        .frame(width: 500)
        .background(Theme.background)
        .onDisappear {
            fetchTask?.cancel()
            synthTask?.cancel()
            player?.stop()
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.secondary.opacity(0.15)))
            }
            .buttonStyle(.borderless)
            Image(systemName: "headphones")
                .font(.system(size: 14))
                .foregroundColor(.indigo)
            Text("Webpage to Audio")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: URL input

    private var urlRow: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                HStack {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    TextField("https://example.com/article", text: $urlText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                        .onSubmit { startFetch() }
                    if !urlText.isEmpty {
                        Button(action: { urlText = ""; article = nil; audioData = nil; phase = .idle }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            Button("Load") { startFetch() }
                .buttonStyle(SmallWebButtonStyle(tint: .accentColor))
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || phase == .fetching || phase == .extracting)
        }
    }

    // MARK: Article card

    private func articleCard(_ a: Article) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(a.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label("\(a.wordCount) words", systemImage: "doc.text")
                Label("~\(a.estimatedMinutes) min audio", systemImage: "clock")
            }
            .font(.system(size: 10))
            .foregroundColor(Theme.textSecondary)

            Text(a.preview + (a.body.count > 280 ? "…" : ""))
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(4)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: Phase indicator

    @ViewBuilder
    private var phaseRow: some View {
        switch phase {
        case .fetching:
            statusRow("Fetching page…", spinning: true)
        case .extracting:
            statusRow("Extracting article text…", spinning: true)
        case .synthesizing:
            VStack(alignment: .leading, spacing: 6) {
                statusRow("Synthesising audio…", spinning: true)
                if let a = article {
                    Text("~\(a.estimatedMinutes) min of audio · this may take a while for long articles")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }
                Button("Cancel") {
                    synthTask?.cancel()
                    synthTask = nil
                    phase = .idle
                }
                .buttonStyle(SmallWebButtonStyle(tint: .red.opacity(0.7)))
            }
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Audio ready")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .font(.system(size: 12))
        case .idle, .failed:
            if article != nil {
                Button("Generate Audio") { startSynth() }
                    .buttonStyle(SmallWebButtonStyle(tint: .indigo))
                    .disabled(!ttsEngine.isReady)
            }
        }
    }

    private func statusRow(_ text: String, spinning: Bool) -> some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func errorRow(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text(msg)
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
    }

    // MARK: Playback bar

    private var playbackBar: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                HStack(spacing: 5) {
                    Image(systemName: player != nil ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                    Text(player != nil ? "Stop" : "Play")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(SmallWebButtonStyle(tint: player != nil ? .red.opacity(0.7) : .accentColor))

            Button(action: saveAudio) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 11))
                    Text("Save to Downloads")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(SmallWebButtonStyle(tint: .secondary.opacity(0.6)))

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.5))
    }

    // MARK: Actions

    private func startFetch() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        fetchTask?.cancel()
        article   = nil
        audioData = nil
        phase     = .fetching

        fetchTask = Task {
            do {
                let a = try await ArticleReader.fetch(url)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    article = a
                    phase   = .idle
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func startSynth() {
        guard let a = article else { return }
        synthTask?.cancel()
        audioData = nil
        phase     = .synthesizing

        synthTask = Task {
            let data = await ttsEngine.synthesizeRaw(text: a.body)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                audioData = data
                phase     = data != nil ? .ready : .failed("Synthesis failed — check TTS engine status.")
            }
        }
    }

    private func togglePlay() {
        guard let data = audioData else { return }
        if let p = player {
            p.stop()
            player = nil
            return
        }
        // Write to temp file — NSSound needs a URL
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendragon_article_\(UUID().uuidString).wav")
        try? data.write(to: tmp)
        if let snd = NSSound(contentsOf: tmp, byReference: false) {
            snd.delegate = SoundDelegate.shared
            SoundDelegate.shared.onFinish = {
                Task { @MainActor in self.player = nil }
            }
            snd.play()
            player = snd
        }
    }

    private func saveAudio() {
        guard let data = audioData, let a = article else { return }
        let safe = a.title
            .replacingOccurrences(of: "[/:\\\\*?\"<>|\\r\\n]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let name = String(safe.prefix(60).isEmpty ? "Article" : safe.prefix(60)) + ".wav"
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first!.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            phase = .failed("Could not save: \(error.localizedDescription)")
        }
    }
}

// MARK: - NSSound delegate trampoline

private final class SoundDelegate: NSObject, NSSoundDelegate {
    static let shared = SoundDelegate()
    var onFinish: (() -> Void)?
    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) { onFinish?() }
}

// MARK: - Button style

private struct SmallWebButtonStyle: ButtonStyle {
    var tint: Color = Color.secondary.opacity(0.6)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(configuration.isPressed ? 0.25 : 0.12))
            )
    }
}
