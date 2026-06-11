import SwiftUI

// MARK: - App Delegate
// Intercepts applicationShouldTerminate so we can await the llama backend
// shutdown before exit() runs the C++ static destructors.
// Without this, ggml's Metal device is freed by a static dtor while a
// background rsets-init dispatch block is still sleeping → ggml_abort().
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    weak var engine:    ChatEngine?
    weak var ttsEngine: TTSEngine?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine, let ttsEngine else { return .terminateNow }

        Task { @MainActor in
            // Signal any in-flight generation to stop (sets atomic flag checked
            // each token, so the generate loop exits within one decode step).
            engine.stopGenerating()

            // Await shutdown on the LlamaEngine actor — this serialises behind
            // any still-running generate() call, waits for it to return, then
            // frees the context, model, and calls llama_backend_free().
            await engine.shutdownForTermination()

            // TTS is synchronous — safe to call after the actor work is done.
            ttsEngine.shutdown()

            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}

// MARK: - App

@main
struct PendragonApp: App {
    static let version = "v0.90030"

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine    = ChatEngine()
    @StateObject private var ttsEngine = TTSEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, ttsEngine: ttsEngine)
                .frame(minWidth: 750, minHeight: 500)
                .preferredColorScheme(.dark)
                .onAppear {
                    // Wire delegate → engines so it can drive shutdown.
                    appDelegate.engine    = engine
                    appDelegate.ttsEngine = ttsEngine
                    engine.ttsEngine      = ttsEngine
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1000, height: 700)
    }
}

struct ContentView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var ttsEngine: TTSEngine
    @State private var sidebarVisible = true
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // One seamless gradient behind sidebar AND chat — the panels above it
            // are translucent glass, so the glow reads through the whole window.
            AuroraBackground()
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(engine: engine, chatStore: engine.chatStore,
                                sidebarVisible: $sidebarVisible, showSettings: $showSettings)
                        .frame(width: 240)
                    Divider()
                }
                ChatView(engine: engine, ttsEngine: ttsEngine,
                         sidebarVisible: $sidebarVisible, showSettings: $showSettings)
            }
        }
        .task { ttsEngine.start() }
        .sheet(isPresented: $showSettings) {
            SettingsView(ttsEngine: ttsEngine, engine: engine, isPresented: $showSettings)
                .frame(minWidth: 660, idealWidth: 700, minHeight: 480, idealHeight: 520)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Window background

/// Deep aurora gradient drawn once behind the whole window.
/// Kept dark and low-saturation so text contrast is unaffected; the glassy
/// panels above (sidebar, input bar) pick up the colour through their blur.
struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            // Indigo bloom — upper left, the dominant glow
            RadialGradient(
                colors: [Color(red: 0.30, green: 0.24, blue: 0.78).opacity(0.34), .clear],
                center: UnitPoint(x: 0.05, y: -0.05), startRadius: 0, endRadius: 760)
            // Magenta-violet bloom — lower right
            RadialGradient(
                colors: [Color(red: 0.62, green: 0.22, blue: 0.58).opacity(0.24), .clear],
                center: UnitPoint(x: 1.05, y: 1.10), startRadius: 0, endRadius: 820)
            // Teal accent — upper right, faint
            RadialGradient(
                colors: [Color(red: 0.12, green: 0.55, blue: 0.62).opacity(0.16), .clear],
                center: UnitPoint(x: 0.92, y: -0.12), startRadius: 0, endRadius: 600)
            // Gentle darkening toward the bottom grounds the composition
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.30)],
                startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass

/// System Liquid Glass (macOS 26+) with a tint, falling back to a translucent
/// fill over `ultraThinMaterial` on older systems. The deployment target is
/// 13.3, so the runtime check keeps the app launchable there.
struct LiquidGlassBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(tint))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    /// Liquid-glass panel background clipped to a rounded rect.
    func liquidGlass(cornerRadius: CGFloat, tint: Color) -> some View {
        modifier(LiquidGlassBackground(cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Theme Colors

enum Theme {
    static let background     = Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0))
    static let sidebar        = Color(nsColor: NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0))
    static let surface        = Color(nsColor: NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1.0))
    static let surfaceHover   = Color(nsColor: NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0))
    /// Slightly richer background used for the input bar card
    static let inputBg        = Color(nsColor: NSColor(red: 0.17, green: 0.17, blue: 0.20, alpha: 1.0))
    // Used as Liquid Glass tints — moderate alpha keeps the glass readable
    // but lets the aurora gradient glow through.
    static let userBubble     = Color(nsColor: NSColor(red: 0.22, green: 0.25, blue: 0.38, alpha: 0.60))
    static let assistantBubble = Color(nsColor: NSColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 0.50))
    static let textPrimary    = Color(nsColor: NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1.0))
    static let textSecondary  = Color(nsColor: NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1.0))
    static let codeBg         = Color(nsColor: NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0))
    static let divider        = Color(nsColor: NSColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1.0))
    /// Subtle 1-pt border used on cards
    static let cardBorder     = Color(white: 1.0, opacity: 0.07)
    /// Slightly brighter top-edge highlight on raised cards
    static let cardTopEdge    = Color(white: 1.0, opacity: 0.11)
}
