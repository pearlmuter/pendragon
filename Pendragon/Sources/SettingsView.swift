import SwiftUI

// MARK: - Settings Panel

struct SettingsView: View {
    @ObservedObject var ttsEngine: TTSEngine
    @ObservedObject var engine: ChatEngine
    @Binding var isPresented: Bool

    enum Section: String, CaseIterable {
        case voice   = "Voice"
        case general = "General"
        case about   = "About"
        var icon: String {
            switch self {
            case .voice:   return "waveform.circle"
            case .general: return "gearshape"
            case .about:   return "info.circle"
            }
        }
    }

    @State private var selectedSection: Section = .voice

    var body: some View {
        HStack(spacing: 0) {
            sidebarPanel
            Divider()
            detailPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }

    // MARK: - Sidebar

    private var sidebarPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.borderless)
                .help("Close Settings")
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().opacity(0.4)

            VStack(spacing: 2) {
                ForEach(Section.allCases, id: \.self) { section in
                    SidebarRow(icon: section.icon, label: section.rawValue,
                               isSelected: selectedSection == section) { selectedSection = section }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Spacer()
        }
        .frame(width: 175)
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private var detailPanel: some View {
        switch selectedSection {
        case .voice:   VoiceSection(ttsEngine: ttsEngine)
        case .general: GeneralSection(ttsEngine: ttsEngine, engine: engine)
        case .about:   AboutSection(ttsEngine: ttsEngine, engine: engine)
        }
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? Theme.textPrimary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.18)
                          : isHovering ? Theme.surfaceHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Voice Section

private struct VoiceSection: View {
    @ObservedObject var ttsEngine: TTSEngine
    @State private var isPreviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Engine status bar ─────────────────────────────────────────
            engineStatusBar
            Divider().opacity(0.4)

            // ── Model picker ──────────────────────────────────────────────
            modelPicker
            Divider().opacity(0.4)

            // ── Model-specific content ────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if ttsEngine.qwen3Model == .voiceDesign {
                        voiceDesignEditor
                    } else {
                        speakerGrid
                        emotionEditor
                    }
                    languagePicker
                }
                .padding(16)
            }

            Divider().opacity(0.4)
            speedAndPreviewBar
        }
    }

    // MARK: Engine status

    private var engineStatusBar: some View {
        HStack(spacing: 8) {
            if ttsEngine.isStarting {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Loading TTS daemon…")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else if let err = ttsEngine.startError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            } else if ttsEngine.isReady {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Qwen3-TTS ready")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text("TTS not loaded")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                Button("Load") { ttsEngine.start() }
                    .buttonStyle(SmallButtonStyle(tint: .accentColor))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface.opacity(0.5))
    }

    // MARK: Model picker (Custom Voice / Voice Design)

    private var modelPicker: some View {
        VStack(spacing: 10) {
            // Top-level: Custom Voice vs Voice Design
            HStack(spacing: 8) {
                logicalModelTab(isCustomVoice: true)
                logicalModelTab(isCustomVoice: false)
            }
            // Sub-picker: size, only shown for Custom Voice
            if ttsEngine.qwen3Model.isCustomVoice {
                HStack(spacing: 0) {
                    sizeTab(.customVoiceSmall, label: "Compact  0.6B", detail: "Faster, less RAM")
                    sizeTab(.customVoice,      label: "Full  1.7B",     detail: "Best quality")
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func logicalModelTab(isCustomVoice: Bool) -> some View {
        let m: Qwen3Model = isCustomVoice
            ? (ttsEngine.qwen3Model.isCustomVoice ? ttsEngine.qwen3Model : .customVoice)
            : .voiceDesign
        let selected = ttsEngine.qwen3Model.isCustomVoice == isCustomVoice
        return Button(action: {
            ttsEngine.qwen3Model = isCustomVoice
                ? (ttsEngine.qwen3Model.isCustomVoice ? ttsEngine.qwen3Model : .customVoice)
                : .voiceDesign
        }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(selected ? .accentColor : Theme.textPrimary)
                Text(isCustomVoice ? "9 preset speakers + emotion" : "Design any voice from text")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Color.accentColor.opacity(0.13) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? Color.accentColor.opacity(0.5)
                            : Color.secondary.opacity(0.12),
                            lineWidth: selected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func sizeTab(_ model: Qwen3Model, label: String, detail: String) -> some View {
        let selected = ttsEngine.qwen3Model == model
        return Button(action: { ttsEngine.qwen3Model = model }) {
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .accentColor : Theme.textSecondary)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textSecondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(2)
    }

    // MARK: Voice Design editor

    private var voiceDesignEditor: some View {
        settingsGroup("Voice Description") {
            Text("Describe the voice in plain language. The model interprets your description to shape timbre, pace, accent, age, and emotional colour.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.bottom, 4)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.background)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))

                if ttsEngine.voiceDesignPrompt.isEmpty {
                    Text("e.g. A warm, deep baritone narrator — measured and unhurried, like a documentary filmmaker reading by firelight. Slightly gravelly.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary.opacity(0.5))
                        .padding(10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $ttsEngine.voiceDesignPrompt)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 140)
                    .padding(6)
            }

            InfoRow(icon: "info.circle",
                    text: "Include emotion in the description itself — e.g. \"…currently speaking with suppressed urgency.\" The description is sent to the model as-is.")
        }
    }

    // MARK: Speaker grid (Custom Voice)

    private var speakerGrid: some View {
        settingsGroup("Speaker") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 8) {
                ForEach(qwen3Voices) { v in
                    speakerCard(v)
                }
            }
        }
    }

    private func speakerCard(_ v: Qwen3Voice) -> some View {
        let selected = ttsEngine.selectedVoice == v.id
        return Button(action: { ttsEngine.selectedVoice = v.id }) {
            Text(v.displayName)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .accentColor : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.accentColor.opacity(0.13) : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.accentColor.opacity(0.5)
                                : Color.secondary.opacity(0.12),
                                lineWidth: selected ? 1.5 : 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Emotion / style instruct (Custom Voice only)

    private var emotionEditor: some View {
        settingsGroup("Emotion / Style") {
            Text("Optional. Describe the delivery style or emotional tone for this session. Leave empty for natural neutral speech.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.bottom, 4)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.background)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))

                if ttsEngine.emotionInstruct.isEmpty {
                    Text("e.g. Speak warmly, as if talking to an old friend. Unhurried and sincere.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary.opacity(0.5))
                        .padding(10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $ttsEngine.emotionInstruct)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 100)
                    .padding(6)
            }
        }
    }

    // MARK: Language picker

    private var languagePicker: some View {
        settingsGroup("Output Language") {
            Text("Hint the model about the language of your text. \"Auto\" works well for English and most common languages, but setting it explicitly can improve pronunciation.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.bottom, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                 GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 6) {
                ForEach(qwen3Languages) { lang in
                    langChip(lang)
                }
            }
        }
    }

    private func langChip(_ lang: Qwen3Language) -> some View {
        let selected = ttsEngine.langCode == lang.id
        return Button(action: { ttsEngine.langCode = lang.id }) {
            Text(lang.displayName)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .accentColor : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Color.accentColor.opacity(0.13) : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(selected ? Color.accentColor.opacity(0.5)
                                : Color.secondary.opacity(0.12),
                                lineWidth: selected ? 1.5 : 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Speed + Preview bar

    private var speedAndPreviewBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Speed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            Slider(value: Binding(
                get: { Double(ttsEngine.speechSpeed) },
                set: { ttsEngine.speechSpeed = Float($0) }
            ), in: 0.5...2.0, step: 0.05)
            .frame(maxWidth: 180)
            .tint(.accentColor)

            Text(String(format: "%.2g×", ttsEngine.speechSpeed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)

            Spacer()

            Button("Reset") {
                withAnimation(.spring(duration: 0.2)) { ttsEngine.speechSpeed = 1.0 }
            }
            .buttonStyle(SmallButtonStyle())
            .opacity(abs(ttsEngine.speechSpeed - 1.0) > 0.01 ? 1 : 0)

            Button(action: previewVoice) {
                HStack(spacing: 5) {
                    if isPreviewing {
                        ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: ttsEngine.isSpeaking ? "stop.fill" : "play.fill")
                            .font(.system(size: 9))
                    }
                    Text(ttsEngine.isSpeaking ? "Stop" : "Preview")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(SmallButtonStyle(tint: ttsEngine.isSpeaking ? .red.opacity(0.7) : .accentColor))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.5))
    }

    private func previewVoice() {
        if ttsEngine.isSpeaking { ttsEngine.stopSpeaking(); isPreviewing = false; return }
        isPreviewing = true
        let sampleText: String
        switch ttsEngine.qwen3Model {
        case .voiceDesign:
            sampleText = "Hello. This is a preview of your designed voice."
        case .customVoice, .customVoiceSmall:
            let name = qwen3Voices.first { $0.id == ttsEngine.selectedVoice }?.displayName
                       ?? ttsEngine.selectedVoice
            sampleText = "Hello, I'm \(name). This is how I sound."
        }
        ttsEngine.speak(text: sampleText)
        // Reset the previewing spinner once speaking begins
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isPreviewing = false }
    }
}

// MARK: - Small button style

private struct SmallButtonStyle: ButtonStyle {
    var tint: Color = Color.secondary.opacity(0.6)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(configuration.isPressed ? 0.25 : 0.12))
            )
    }
}

// MARK: - Context Size Card

private struct ContextSizeCard: View {
    let option: ContextSizeOption
    let isSelected: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                Text(option.label)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? .accentColor : Theme.textPrimary)
                Text(String(format: "~%.1f GB KV", option.kvCacheGB))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Divider().opacity(0.3)
                HStack(spacing: 3) {
                    Image(systemName: speedIcon)
                        .font(.system(size: 8))
                        .foregroundColor(speedColor)
                    Text(option.speedNote)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(speedColor)
                }
                Text(option.useCaseLabel)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textSecondary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.accentColor.opacity(0.15)
                          : isHovering ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55)
                            : Color.secondary.opacity(0.12),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
            .opacity(isDisabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .help(isDisabled ? "Cannot resize while generating" : option.useCaseLabel)
    }

    private var speedIcon: String {
        switch option {
        case .k8:   return "hare.fill"
        case .k32:  return "hare"
        case .k128: return "tortoise"
        case .k256: return "tortoise.fill"
        }
    }
    private var speedColor: Color {
        switch option {
        case .k8, .k32: return .green.opacity(0.8)
        case .k128:     return .orange.opacity(0.8)
        case .k256:     return .red.opacity(0.7)
        }
    }
}

// MARK: - General Section

private struct GeneralSection: View {
    @ObservedObject var ttsEngine: TTSEngine
    @ObservedObject var engine: ChatEngine

    private let kvPerTokenKB = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("General")
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── TTS ─────────────────────────────────────────────────
                    settingsGroup("Text-to-Speech") {
                        ToggleRow(
                            icon: "waveform.badge.mic",
                            title: "Auto-speak responses",
                            subtitle: "Automatically read each assistant reply aloud when generation finishes.",
                            isOn: $ttsEngine.autoSpeak
                        )
                        Divider().opacity(0.4)
                        HStack(spacing: 10) {
                            Image(systemName: ttsEngine.isReady ? "checkmark.circle.fill" : "clock.circle")
                                .font(.system(size: 14))
                                .foregroundColor(ttsEngine.isReady ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Qwen3-TTS 1.7B · MLX Audio")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Text(ttsEngine.isReady
                                     ? "Daemon ready · \(ttsEngine.qwen3Model.displayName) mode"
                                     : ttsEngine.isStarting ? "Loading daemon…" : "Not loaded")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            if !ttsEngine.isReady && !ttsEngine.isStarting {
                                Button("Load now") { ttsEngine.start() }
                                    .buttonStyle(SmallButtonStyle(tint: .accentColor))
                            } else if ttsEngine.isStarting {
                                ProgressView().scaleEffect(0.65)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // ── Context window ──────────────────────────────────────
                    settingsGroup("Context Window") {
                        Text("Gemma 4 12B supports up to 256K tokens. Larger contexts use more RAM " +
                             "but unlock longer documents, codebases, and multi-turn history. " +
                             "Changing the size clears the current conversation (weights stay loaded).")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                            .padding(.bottom, 6)

                        HStack(spacing: 8) {
                            ForEach(ContextSizeOption.allCases) { option in
                                ContextSizeCard(
                                    option: option,
                                    isSelected: engine.contextSizeOption == option,
                                    isDisabled: engine.isGenerating
                                ) { engine.contextSizeOption = option }
                            }
                        }
                        Divider().opacity(0.4).padding(.vertical, 4)
                        InfoRow(icon: "cpu",
                                text: "Hybrid SWA architecture: 40 sliding-window layers hold a fixed 1 024-token window (~335 MB). " +
                                      "Only 8 global attention layers scale linearly (~\(kvPerTokenKB) KB per token). " +
                                      "Flash attention enabled.")
                    }

                    // ── Language note ────────────────────────────────────────
                    settingsGroup("Language Support") {
                        InfoRow(icon: "globe", text:
                            "Qwen3-TTS supports 10 languages: English, Chinese, Japanese, Korean, German, French, Russian, Portuguese, Spanish, and Italian.")
                        Divider().opacity(0.4)
                        InfoRow(icon: "textformat.abc", text:
                            "Markdown is stripped before synthesis. Code blocks, URLs, and special symbols are removed so they don't interrupt speech.")
                    }
                }
                .padding(20)
            }
        }
    }
}

// MARK: - About Section

private struct AboutSection: View {
    @ObservedObject var ttsEngine: TTSEngine
    @ObservedObject var engine: ChatEngine

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("About")
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    settingsGroup("Pendragon") {
                        HStack(spacing: 14) {
                            Image("PendragonAvatar")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Pendragon")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text("Version \(appVersion)")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                                Text("On-device AI assistant")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary.opacity(0.7))
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    settingsGroup("Language Model") {
                        modelInfoRow(label: "Architecture", value: "Gemma 4 12B")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Quantisation", value: "Q4_K_M")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Context window", value: "\(engine.contextSizeOption.label) tokens")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Vision", value: "Gemma 4 mm-projector · up to 4 images · 70–1 120 tokens each")
                        Divider().opacity(0.4)
                        InfoRow(icon: "lock.shield",
                                text: "All inference runs entirely on-device. No data is sent to any server.")
                    }

                    settingsGroup("Active Settings") {
                        modelInfoRow(label: "Version",      value: PendragonApp.version)
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Context size", value: "\(engine.contextSizeOption.label) (\(engine.contextSizeOption.rawValue) tokens)")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Boost",        value: engine.boostEnabled ? "On" : "Off (quiet)")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Thinking",     value: engine.thinkingEnabled ? "On" : "Off")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Auto-speak",   value: ttsEngine.autoSpeak ? "On" : "Off")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "TTS mode",     value: ttsEngine.qwen3Model.displayName)
                        Divider().opacity(0.4)
                        modelInfoRow(label: "TTS voice",    value: ttsEngine.qwen3Model == .voiceDesign
                            ? (ttsEngine.voiceDesignPrompt.isEmpty ? "No description set" : "Custom design")
                            : ttsEngine.selectedVoice)
                    }

                    settingsGroup("Text-to-Speech") {
                        modelInfoRow(label: "Engine",   value: "Qwen3-TTS 1.7B")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Backend",  value: "MLX Audio · Apple Silicon")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "License",  value: "Apache 2.0")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Output",   value: "24 kHz · WAV · SNAC codec")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Languages", value: "10 languages incl. EN, ZH, JA, DE, FR")
                        Divider().opacity(0.4)
                        InfoRow(icon: "info.circle",
                                text: "Qwen3-TTS runs via a persistent Python daemon (mlx-audio). " +
                                      "First synthesis per session takes ~5-8 s while the model loads into RAM. " +
                                      "Subsequent calls take ~3 s. Peak RAM: ~8 GB for the TTS model alone.")
                    }
                }
                .padding(20)
            }
        }
    }

    private func modelInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Shared helpers

private func sectionHeader(_ title: String) -> some View {
    VStack(spacing: 0) {
        HStack {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        Divider().opacity(0.4)
    }
}

private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.textSecondary.opacity(0.7))
            .textCase(.uppercase)
            .kerning(0.5)
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.1), lineWidth: 0.5))
    }
}

private struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }
}
