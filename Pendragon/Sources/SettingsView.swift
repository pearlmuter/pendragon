import SwiftUI

// MARK: - Voice Catalogue

struct VoiceInfo: Identifiable, Equatable {
    let id: String           // Kokoro voice ID, e.g. "af_heart"
    let displayName: String  // Human-readable name
    let gender: Gender
    let accent: Accent
    let grade: Grade
    let description: String
    let traits: [String]

    enum Gender: String { case female, male
        var symbol: String { self == .female ? "♀" : "♂" }
        var color: Color    { self == .female ? .pink.opacity(0.85) : .blue.opacity(0.85) }
    }

    enum Accent: String, CaseIterable {
        case american = "American English"
        case british  = "British English"
        var flag: String  { self == .american ? "🇺🇸" : "🇬🇧" }
        var short: String { self == .american ? "AmE" : "BrE" }
        var espeakLang: String { self == .american ? "en-us" : "en-gb" }
    }

    struct Grade: Equatable {
        let label: String  // e.g. "A", "B+", "C−"
        let tier: Int      // 0=A family, 1=B family, 2=C family, 3=D
        var color: Color {
            switch tier {
            case 0: return Color(red: 0.30, green: 0.85, blue: 0.45)
            case 1: return Color(red: 0.70, green: 0.90, blue: 0.20)
            case 2: return .orange
            default: return .secondary
            }
        }
        static func gradeOf(_ s: String) -> Grade {
            let tier: Int
            switch s.first {
            case "A": tier = 0
            case "B": tier = 1
            case "C": tier = 2
            default:  tier = 3
            }
            return Grade(label: s, tier: tier)
        }
    }

    static func == (lhs: VoiceInfo, rhs: VoiceInfo) -> Bool { lhs.id == rhs.id }
}

// MARK: - Kokoro v1.0 voice catalogue
// Grades and descriptions are based on the Kokoro model card and community evaluation.
// Language support: all voices are English-only (American or British RP).
// The espeak-ng phonemiser is used for text normalisation; it supports only en-us / en-gb.

let kokoroVoiceCatalogue: [VoiceInfo] = [
    // ── American English · Female ──────────────────────────────────────────
    .init(id: "af_heart",    displayName: "Heart",    gender: .female, accent: .american,
          grade: .gradeOf("A"),   description: "Warm, expressive, and natural. Top-rated overall.",
          traits: ["Warm", "Expressive"]),
    .init(id: "af_bella",    displayName: "Bella",    gender: .female, accent: .american,
          grade: .gradeOf("A−"),  description: "Smooth and polished. Ideal for longer reads.",
          traits: ["Smooth", "Polished"]),
    .init(id: "af_aoede",    displayName: "Aoede",    gender: .female, accent: .american,
          grade: .gradeOf("B+"),  description: "Bright and articulate. Slightly upbeat.",
          traits: ["Bright", "Clear"]),
    .init(id: "af_kore",     displayName: "Kore",     gender: .female, accent: .american,
          grade: .gradeOf("B+"),  description: "Neutral, versatile all-rounder.",
          traits: ["Neutral", "Versatile"]),
    .init(id: "af_sarah",    displayName: "Sarah",    gender: .female, accent: .american,
          grade: .gradeOf("B+"),  description: "Natural pacing with a pleasant tone.",
          traits: ["Pleasant"]),
    .init(id: "af_nicole",   displayName: "Nicole",   gender: .female, accent: .american,
          grade: .gradeOf("B"),   description: "Clear and friendly.",
          traits: ["Friendly"]),
    .init(id: "af_sky",      displayName: "Sky",      gender: .female, accent: .american,
          grade: .gradeOf("B"),   description: "Light, clear, good intelligibility.",
          traits: ["Light"]),
    .init(id: "af_nova",     displayName: "Nova",     gender: .female, accent: .american,
          grade: .gradeOf("C+"),  description: "Energetic cadence, faster natural pace.",
          traits: ["Energetic"]),
    .init(id: "af_alloy",    displayName: "Alloy",    gender: .female, accent: .american,
          grade: .gradeOf("C"),   description: "Neutral. Adequate quality.",
          traits: []),
    .init(id: "af_river",    displayName: "River",    gender: .female, accent: .american,
          grade: .gradeOf("C−"),  description: "Calm, flowing delivery.",
          traits: ["Calm"]),
    .init(id: "af_jessica",  displayName: "Jessica",  gender: .female, accent: .american,
          grade: .gradeOf("D"),   description: "Experimental. Quality may vary.",
          traits: ["Experimental"]),
    // ── American English · Male ────────────────────────────────────────────
    .init(id: "am_michael",  displayName: "Michael",  gender: .male, accent: .american,
          grade: .gradeOf("A"),   description: "Deep, authoritative, and clear. Best American male.",
          traits: ["Deep", "Authoritative"]),
    .init(id: "am_fenrir",   displayName: "Fenrir",   gender: .male, accent: .american,
          grade: .gradeOf("B+"),  description: "Strong and confident. Slightly dramatic.",
          traits: ["Strong"]),
    .init(id: "am_puck",     displayName: "Puck",     gender: .male, accent: .american,
          grade: .gradeOf("B+"),  description: "Lively and engaging. Great for storytelling.",
          traits: ["Lively"]),
    .init(id: "am_eric",     displayName: "Eric",     gender: .male, accent: .american,
          grade: .gradeOf("B+"),  description: "Warm baritone with natural rhythm.",
          traits: ["Warm", "Baritone"]),
    .init(id: "am_liam",     displayName: "Liam",     gender: .male, accent: .american,
          grade: .gradeOf("B"),   description: "Youthful and friendly.",
          traits: ["Youthful"]),
    .init(id: "am_echo",     displayName: "Echo",     gender: .male, accent: .american,
          grade: .gradeOf("C+"),  description: "Clean, neutral delivery.",
          traits: ["Clean"]),
    .init(id: "am_onyx",     displayName: "Onyx",     gender: .male, accent: .american,
          grade: .gradeOf("C"),   description: "Dark, resonant tone.",
          traits: ["Resonant"]),
    .init(id: "am_adam",     displayName: "Adam",     gender: .male, accent: .american,
          grade: .gradeOf("C−"),  description: "Straightforward delivery.",
          traits: []),
    .init(id: "am_santa",    displayName: "Santa",    gender: .male, accent: .american,
          grade: .gradeOf("D"),   description: "Jolly, festive character voice.",
          traits: ["Festive"]),
    // ── British English · Female ───────────────────────────────────────────
    .init(id: "bf_emma",     displayName: "Emma",     gender: .female, accent: .british,
          grade: .gradeOf("A"),   description: "Refined RP accent. Elegant and precise. Top BrE voice.",
          traits: ["Elegant", "RP"]),
    .init(id: "bf_isabella", displayName: "Isabella", gender: .female, accent: .british,
          grade: .gradeOf("B+"),  description: "Warm British tone with clear articulation.",
          traits: ["Warm", "Clear"]),
    .init(id: "bf_alice",    displayName: "Alice",    gender: .female, accent: .british,
          grade: .gradeOf("B"),   description: "Bright and cheerful. Slightly informal.",
          traits: ["Bright", "Cheerful"]),
    .init(id: "bf_lily",     displayName: "Lily",     gender: .female, accent: .british,
          grade: .gradeOf("C+"),  description: "Gentle and soft-spoken.",
          traits: ["Gentle"]),
    // ── British English · Male ─────────────────────────────────────────────
    .init(id: "bm_george",   displayName: "George",   gender: .male, accent: .british,
          grade: .gradeOf("A+"),  description: "Classic RP. Deep, measured. Perfect for formal content.",
          traits: ["Classic", "Formal"]),
    .init(id: "bm_fable",    displayName: "Fable",    gender: .male, accent: .british,
          grade: .gradeOf("A"),   description: "Rich, narrative quality. Ideal for storytelling.",
          traits: ["Rich", "Narrative"]),
    .init(id: "bm_lewis",    displayName: "Lewis",    gender: .male, accent: .british,
          grade: .gradeOf("B+"),  description: "Conversational and natural.",
          traits: ["Conversational"]),
    .init(id: "bm_daniel",   displayName: "Daniel",   gender: .male, accent: .british,
          grade: .gradeOf("B"),   description: "Pleasant British character.",
          traits: ["Pleasant"]),
]

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
            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }

    // MARK: - Sidebar

    private var sidebarPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
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
                    SidebarRow(
                        icon: section.icon,
                        label: section.rawValue,
                        isSelected: selectedSection == section
                    ) { selectedSection = section }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Spacer()
        }
        .frame(width: 175)
        .background(Theme.sidebar)
    }

    // MARK: - Detail router

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
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.18)
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
    @State private var accentFilter: VoiceInfo.Accent? = nil
    @State private var genderFilter: VoiceInfo.Gender? = nil
    @State private var isPreviewing = false

    private var availableIDs: Set<String> {
        Set(ttsEngine.availableVoices)
    }

    private var filtered: [VoiceInfo] {
        kokoroVoiceCatalogue.filter { v in
            let accentOK = accentFilter == nil || v.accent == accentFilter
            let genderOK = genderFilter == nil || v.gender == genderFilter
            return accentOK && genderOK
        }
    }

    private var groupedByAccent: [(VoiceInfo.Accent, [VoiceInfo])] {
        let accents: [VoiceInfo.Accent] = accentFilter.map { [$0] } ?? VoiceInfo.Accent.allCases
        return accents.compactMap { accent in
            let voices = filtered.filter { $0.accent == accent }
            return voices.isEmpty ? nil : (accent, voices)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Model picker ──────────────────────────────────────────────
            ModelPicker(ttsEngine: ttsEngine)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider().opacity(0.4)

            // ── Voice header + filter chips ───────────────────────────────
            HStack(spacing: 8) {
                Text("Voice")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                // Filter chips
                FilterChip(label: "🇺🇸", isOn: accentFilter == .american) {
                    accentFilter = accentFilter == .american ? nil : .american
                }
                FilterChip(label: "🇬🇧", isOn: accentFilter == .british) {
                    accentFilter = accentFilter == .british ? nil : .british
                }
                FilterChip(label: "♀", isOn: genderFilter == .female) {
                    genderFilter = genderFilter == .female ? nil : .female
                }
                FilterChip(label: "♂", isOn: genderFilter == .male) {
                    genderFilter = genderFilter == .male ? nil : .male
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            // Voice list
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedByAccent, id: \.0) { accent, voices in
                        VStack(alignment: .leading, spacing: 6) {
                            // Accent header
                            HStack(spacing: 6) {
                                Text(accent.flag)
                                    .font(.system(size: 14))
                                Text(accent.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.textSecondary)
                                Text("· \(accent.espeakLang)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.textSecondary.opacity(0.6))
                            }
                            .padding(.horizontal, 4)

                            // Voice cards — 2-column adaptive grid
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                                GridItem(.flexible(), spacing: 8)],
                                      spacing: 8) {
                                ForEach(voices) { voice in
                                    VoiceCard(
                                        voice: voice,
                                        isSelected: ttsEngine.selectedVoice == voice.id,
                                        isAvailable: availableIDs.isEmpty || availableIDs.contains(voice.id)
                                    ) {
                                        ttsEngine.selectedVoice = voice.id
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }

            Divider().opacity(0.4)

            // Speed + Preview bar
            speedAndPreviewBar
        }
    }

    private var speedAndPreviewBar: some View {
        HStack(spacing: 16) {
            // Speed label
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Speed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            // Slider
            Slider(value: Binding(
                get: { Double(ttsEngine.speechSpeed) },
                set: { ttsEngine.speechSpeed = Float($0) }
            ), in: 0.5...2.0, step: 0.05)
            .frame(maxWidth: 180)
            .tint(.accentColor)

            // Speed value
            Text(String(format: "%.2g×", ttsEngine.speechSpeed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)

            Spacer()

            // Reset speed
            Button("Reset") {
                withAnimation(.spring(duration: 0.2)) { ttsEngine.speechSpeed = 1.0 }
            }
            .buttonStyle(SmallButtonStyle())
            .opacity(abs(ttsEngine.speechSpeed - 1.0) > 0.01 ? 1 : 0)

            // Preview button
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
            .disabled(isPreviewing && !ttsEngine.isReady)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.5))
    }

    private func previewVoice() {
        if ttsEngine.isSpeaking { ttsEngine.stopSpeaking(); return }
        guard ttsEngine.isReady else {
            isPreviewing = true
            ttsEngine.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { previewVoice() }
            return
        }
        isPreviewing = false
        let voiceName = kokoroVoiceCatalogue.first(where: { $0.id == ttsEngine.selectedVoice })?.displayName
                        ?? ttsEngine.selectedVoice
        ttsEngine.speak(text: "Hello, I'm \(voiceName). This is how I sound.")
    }
}

// MARK: - Model Picker

private struct ModelPicker: View {
    @ObservedObject var ttsEngine: TTSEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Model")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if ttsEngine.isStarting {
                    ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                    Text("Loading…")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(TTSModelVariant.allCases, id: \.self) { variant in
                    ModelCard(
                        variant: variant,
                        isSelected: ttsEngine.selectedModel == variant,
                        isLoading: ttsEngine.isStarting && ttsEngine.selectedModel == variant
                    ) {
                        ttsEngine.selectedModel = variant
                    }
                }
            }

            // Reload notice — shown only when model changed and is reloading
            if ttsEngine.isStarting {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("Reloading model — speech will be available in a moment")
                        .font(.system(size: 10))
                }
                .foregroundColor(Theme.textSecondary.opacity(0.7))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("Switching models reloads the engine. Speech is paused until loading completes.")
                        .font(.system(size: 10))
                }
                .foregroundColor(Theme.textSecondary.opacity(0.5))
            }
        }
    }
}

private struct ModelCard: View {
    let variant: TTSModelVariant
    let isSelected: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                // Top: name + precision badge
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(variant.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text(variant.fileSize)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    // Precision badge
                    Text(variant.precision)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(precisionColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(precisionColor.opacity(0.15)))
                }

                // Quality bar
                MetricBar(label: "Quality", score: variant.qualityScore, color: .green)
                // Speed bar
                MetricBar(label: "Speed", score: variant.speedScore, color: .blue)

                // Recommendation tag
                Text(variant.recommendation)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isSelected ? .accentColor.opacity(0.9) : Theme.textSecondary.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.15)
                          : isHovering ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.12),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 16, height: 16)
                        .padding(6)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(variant.description)
    }

    private var precisionColor: Color {
        switch variant {
        case .fp32: return .purple
        case .fp16: return .teal
        case .int8: return .orange
        }
    }
}

/// A 5-dot progress bar used for quality / speed scores.
private struct MetricBar: View {
    let label: String
    let score: Int    // 1–5
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(Theme.textSecondary.opacity(0.7))
                .frame(width: 36, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i <= score ? color.opacity(0.8) : Color.secondary.opacity(0.15))
                        .frame(width: 14, height: 5)
                }
            }
        }
    }
}

// MARK: - Voice Card

private struct VoiceCard: View {
    let voice: VoiceInfo
    let isSelected: Bool
    let isAvailable: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                // Top row: name + grade badge
                HStack(spacing: 0) {
                    // Gender symbol
                    Text(voice.gender.symbol)
                        .font(.system(size: 10))
                        .foregroundColor(voice.gender.color)
                        .padding(.trailing, 4)

                    Text(voice.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isAvailable ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    // Grade badge
                    Text(voice.grade.label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(voice.grade.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(voice.grade.color.opacity(0.15))
                        )
                }

                // Description
                Text(voice.description)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Trait pills
                if !voice.traits.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(voice.traits, id: \.self) { trait in
                            Text(trait)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.7))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.secondary.opacity(0.1))
                                )
                        }
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.18)
                          : isHovering ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected
                            ? Color.accentColor.opacity(0.6)
                            : Color.secondary.opacity(0.12),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
            .opacity(isAvailable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isAvailable ? voice.description : "Not available in current model build")
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    Capsule()
                        .stroke(isOn ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
                // Token count label
                Text(option.label)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? .accentColor : Theme.textPrimary)

                // RAM estimate
                Text(String(format: "~%.1f GB KV", option.kvCacheGB))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)

                Divider().opacity(0.3)

                // Speed note
                HStack(spacing: 3) {
                    Image(systemName: speedIcon)
                        .font(.system(size: 8))
                        .foregroundColor(speedColor)
                    Text(option.speedNote)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(speedColor)
                }

                // Use-case label
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
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.15)
                          : isHovering ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.12),
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

    // 8 global layers × 4 KV heads × 2 (K+V) × 256 dim × 2 bytes (FP16) = 16 384 bytes ≈ 16 KB per token.
    // 40 SWA layers hold a fixed 1 024-token window (~335 MB) regardless of n_ctx.
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

                        // TTS model status
                        HStack(spacing: 10) {
                            Image(systemName: ttsEngine.isReady ? "checkmark.circle.fill" : "clock.circle")
                                .font(.system(size: 14))
                                .foregroundColor(ttsEngine.isReady ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Kokoro v1.0 ONNX")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Text(ttsEngine.isReady
                                     ? "Model loaded · \(ttsEngine.availableVoices.count) voices available"
                                     : ttsEngine.isStarting ? "Loading…" : "Not loaded — click Listen to load")
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

                        // Four option cards
                        HStack(spacing: 8) {
                            ForEach(ContextSizeOption.allCases) { option in
                                ContextSizeCard(
                                    option: option,
                                    isSelected: engine.contextSizeOption == option,
                                    isDisabled: engine.isGenerating
                                ) {
                                    engine.contextSizeOption = option
                                }
                            }
                        }

                        Divider().opacity(0.4).padding(.vertical, 4)

                        // Architecture note
                        InfoRow(icon: "cpu",
                                text: "Hybrid SWA architecture: 40 sliding-window layers hold a fixed 1 024-token window (~335 MB, same at every context size). " +
                                      "Only 8 global attention layers scale linearly (~\(kvPerTokenKB) KB per token). " +
                                      "Flash attention is enabled — reduces memory bandwidth for global layers significantly.")
                    }

                    // ── Language note ────────────────────────────────────────
                    settingsGroup("Language Support") {
                        InfoRow(icon: "globe", text:
                            "Kokoro v1.0 supports English only — American (en-US) and British RP (en-GB). " +
                            "The text is phonemised by espeak-ng before being fed to the neural model. " +
                            "Foreign words will be read with an English accent.")
                        Divider().opacity(0.4)
                        InfoRow(icon: "textformat.abc", text:
                            "Markdown is stripped before synthesis. Code blocks, URLs, and special symbols " +
                            "are removed so they don't interrupt speech.")
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
                        modelInfoRow(label: "TTS voice",    value: ttsEngine.selectedVoice)
                    }

                    settingsGroup("Text-to-Speech") {
                        modelInfoRow(label: "Engine", value: "Kokoro v1.0")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Active model",
                                     value: "\(ttsEngine.selectedModel.displayName) · \(ttsEngine.selectedModel.precision) · \(ttsEngine.selectedModel.fileSize)")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Backend", value: "ONNX Runtime")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Phonemiser", value: "espeak-ng")
                        Divider().opacity(0.4)
                        modelInfoRow(label: "Output", value: "24 kHz · mono · float32 PCM")
                        Divider().opacity(0.4)
                        InfoRow(icon: "info.circle",
                                text: "Kokoro is an open-weight TTS model. Voices are language-specific: " +
                                      "\"af_\" / \"am_\" use en-US phonemes; \"bf_\" / \"bm_\" use en-GB (RP).")
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
