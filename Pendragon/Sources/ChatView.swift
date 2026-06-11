import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var chatStore: ChatStore   // direct observation → re-renders on every threads change
    @Binding var sidebarVisible: Bool
    @Binding var showSettings: Bool

    private var pinnedThreads: [ChatThread] {
        chatStore.threads.filter { chatStore.isPinned($0) }
    }
    private var unpinnedThreads: [ChatThread] {
        chatStore.threads.filter { !chatStore.isPinned($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar header
            HStack {
                Text("Chats")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { engine.newChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("New Chat")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Thread list
            if chatStore.threads.isEmpty {
                Spacer()
                Text("No chats yet")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.5))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Pinned section
                        if !pinnedThreads.isEmpty {
                            sectionLabel("Pinned")
                            ForEach(pinnedThreads) { thread in
                                threadRow(thread)
                            }
                            if !unpinnedThreads.isEmpty {
                                sectionLabel("Recent")
                            }
                        }
                        // Unpinned section
                        ForEach(unpinnedThreads) { thread in
                            threadRow(thread)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }

            // Settings button at bottom of sidebar
            Divider().opacity(0.4)
            Button(action: { showSettings = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("Settings")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open Settings")
        }
        // Glassy sidebar: dark tint over a blur material so the window gradient
        // shows through without hurting row legibility.
        .background(Theme.sidebar.opacity(0.42))
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary.opacity(0.35))
            .tracking(0.8)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    @ViewBuilder
    private func threadRow(_ thread: ChatThread) -> some View {
        ThreadRow(
            thread: thread,
            isSelected: engine.currentThreadId == thread.id,
            isPinned: chatStore.isPinned(thread),
            isGenerating: engine.generatingThreadId == thread.id,
            onSelect: { engine.selectThread(thread) },
            onPin:   { engine.togglePin(thread) },
            onDelete: { withAnimation(.easeOut(duration: 0.2)) { engine.deleteThread(thread) } }
        )
    }
}

struct ThreadRow: View {
    let thread: ChatThread
    let isSelected: Bool
    let isPinned: Bool
    var isGenerating: Bool = false
    let onSelect: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var isPinHovering = false
    @State private var isDeleteHovering = false
    /// Pending work item that will clear hover state after the debounce window.
    @State private var hoverResetItem: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 6) {

            // Pin — always visible when pinned (orange), fades in on hover
            Button(action: onPin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundColor(pinIconColor)
                    .frame(width: 14, height: 14)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isPinHovering ? Color.primary.opacity(0.12) : Color.clear)
                    )
            }
            .buttonStyle(.borderless)
            .opacity(isPinned || isHovering ? 1 : 0)
            .frame(width: 22)
            .onHover { h in
                isPinHovering = h
                // Cursor entered the pin button — keep the row "hovered" and
                // cancel any pending reset that the outer container scheduled.
                if h { keepHover() }
            }

            // Title + date — not hittable so taps fall through to onTapGesture
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(thread.title)
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                    if isGenerating {
                        GeneratingDot()
                    }
                }
                Text(formatDate(thread.updatedAt))
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }
            .allowsHitTesting(false)

            Spacer()

            // Delete — always in the hierarchy so .onHover fires even when
            // opacity is 0 (removing the view with `if` would break hover).
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(deleteIconColor)
                    .frame(width: 14, height: 14)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isDeleteHovering ? Color.red.opacity(0.12) : Color.clear)
                    )
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            .onHover { h in
                isDeleteHovering = h
                if h { keepHover() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? Color.clear          // gradient overlay below handles fill
                      : (isHovering ? Theme.surfaceHover : Color.clear))
        )
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.45),
                                    Color.accentColor.opacity(0.12)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { h in
            if h {
                keepHover()
            } else {
                // Cursor may be heading toward a child button — defer clearing
                // so the button's .onHover has a chance to call keepHover().
                // The callback only clears state when no inner button is active.
                scheduleHoverReset()
            }
        }
        .onTapGesture { onSelect() }
    }

    // MARK: - Hover helpers

    private func keepHover() {
        hoverResetItem?.cancel()
        hoverResetItem = nil
        isHovering = true
    }

    private func scheduleHoverReset() {
        hoverResetItem?.cancel()
        let item = DispatchWorkItem {
            // Only clear if the cursor isn't sitting on one of the inner buttons.
            if !isPinHovering && !isDeleteHovering {
                isHovering = false
            }
        }
        hoverResetItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    // MARK: - Appearance helpers

    private var pinIconColor: Color {
        if isPinned { return isSelected ? .white : .orange }
        if isPinHovering { return isSelected ? .white : .primary }
        return isSelected ? .white.opacity(0.5) : .secondary.opacity(0.6)
    }

    private var deleteIconColor: Color {
        isDeleteHovering ? .red : (isSelected ? .white.opacity(0.7) : .secondary)
    }

    private func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let f = DateFormatter()
            f.dateFormat = "d MMM"
            return f.string(from: date)
        }
    }
}

// MARK: - Chat View

struct ChatView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var ttsEngine: TTSEngine
    @Binding var sidebarVisible: Bool
    @Binding var showSettings: Bool
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @State private var userHasScrolledUp = true   // auto-follow is opt-in, not default
    @State private var expandedImage: NSImage? = nil
    @State private var showCapabilities   = false
    @State private var titleBarWidth: CGFloat = 1000

    // Article-to-audio state
    enum ArticlePhase { case none, loading, ready, synthesizing }
    @State private var articlePhase: ArticlePhase = .none
    @State private var pendingArticle: Article?
    @State private var articleFetchTask: Task<Void, Never>?
    @State private var articleSynthTask: Task<Void, Never>?
    @State private var webAudioMode = false
    /// Translation of the last assistant message, driven by the toolbar button

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()

            if !engine.isModelLoaded {
                loadingView
            } else {
                chatArea
                if !engine.pendingImages.isEmpty || engine.pendingAudioSamples != nil || engine.pendingPDFText != nil {
                    Divider()
                    pendingMediaPreview
                }
                inputBar
            }
        }
        // Transparent — the window-level AuroraBackground shows through.
        // Measure the AVAILABLE panel width here (this VStack always fills it)
        // — measuring the title-bar HStack itself reports its overflowing
        // content width, which defeats the breakpoints.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { titleBarWidth = geo.size.width }
                    .onChange(of: geo.size.width) { titleBarWidth = $0 }
            }
        )
        .sheet(isPresented: $showCapabilities) {
            CapabilitiesView(isPresented: $showCapabilities) { example in
                inputText = example
                inputFocused = true
            }
            .frame(minWidth: 620, idealWidth: 660, minHeight: 480, idealHeight: 560)
            .preferredColorScheme(.dark)
        }
        // Menu-bar Edit > Paste (keyboard Cmd+V is handled by the monitor below)
        .onPasteCommand(of: [.png, .tiff, .jpeg, .fileURL, .pdf, .plainText]) { _ in
            engine.pasteFromClipboard(appendToInput: { text in
                handlePastedText(text)
            })
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Only intercept when the message input field has focus
                guard inputFocused else { return event }

                let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])

                // ── Return key (keyCode 36) ──────────────────────────────────
                if event.keyCode == 36 {
                    if flags == .shift {
                        // Shift+Enter → insert newline at the cursor
                        NSApp.sendAction(
                            #selector(NSText.insertNewlineIgnoringFieldEditor(_:)),
                            to: nil, from: nil
                        )
                        return nil   // consume — do not trigger onSubmit
                    } else if flags.isEmpty {
                        // Plain Enter → send message
                        DispatchQueue.main.async { sendMessage() }
                        return nil
                    }
                }

                // ── Cmd+V ────────────────────────────────────────────────────
                if flags == .command,
                   event.charactersIgnoringModifiers?.lowercased() == "v" {
                    // Try to handle as file / image / PDF first.
                    // If nothing special is on the clipboard, fall through so the
                    // text field pastes plain text normally.
                    if engine.pasteFromClipboard(appendToInput: { text in
                        handlePastedText(text)
                    }) {
                        return nil   // consumed
                    }
                    // Fall through for plain text
                }

                return event
            }
        }
    }

    private var titleBar: some View {
        // Two-stage breakpoints: version number goes first, button labels second.
        let hideVersion = titleBarWidth < 740
        let compact     = titleBarWidth < 660
        return HStack {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { sidebarVisible.toggle() } }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")

            HStack(spacing: 5) {
                Text("Pendragon")
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize()
                if !hideVersion {
                    Text(PendragonApp.version)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.5))
                        .fixedSize()
                        .padding(.top, 2)
                }
            }

            if engine.tokenCount > 0 || engine.isCompacting {
                CompactTokenLabel(
                    tokenCount: engine.tokenCount,
                    isCompacting: engine.isCompacting
                )
            }

            // Gear icon — shown when sidebar is hidden (otherwise use sidebar bottom button)
            if !sidebarVisible {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            if engine.tokensPerSecond > 0 && !engine.isGenerating {
                Text(String(format: "%.1f t/s", engine.tokensPerSecond))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.surface)
                    )
                    .help("Tokens per second from last response")
            }

            Spacer()

            // Skills — what can Pendragon do?
            Button(action: { showCapabilities = true }) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundColor(.yellow.opacity(0.85))
            }
            .buttonStyle(.borderless)
            .help("See everything Pendragon can do")

            ToolbarToggleButton(
                icon: engine.thinkingEnabled ? "brain.head.profile.fill" : "brain.head.profile",
                label: engine.thinkingEnabled ? "Thinking" : "Direct",
                isActive: engine.thinkingEnabled,
                activeColor: .purple,
                isDisabled: engine.isGenerating,
                compact: compact,
                help: engine.thinkingEnabled ? "Thinking mode on" : "Direct mode — no reasoning step"
            ) { engine.thinkingEnabled.toggle() }

            ToolbarToggleButton(
                icon: engine.translateEnabled ? "character.bubble.fill" : "character.bubble",
                label: "Translate",
                isActive: engine.translateEnabled,
                activeColor: .teal,
                isDisabled: engine.isGenerating,
                compact: compact,
                help: engine.translateEnabled ? "Translation mode on" : "Translation mode off"
            ) { engine.translateEnabled.toggle() }

            ToolbarToggleButton(
                icon: "globe",
                label: "Search",
                isActive: engine.searchEnabled,
                activeColor: .blue,
                isDisabled: engine.isGenerating,
                compact: compact,
                help: engine.searchEnabled ? "Web search enabled" : "Web search disabled"
            ) { engine.searchEnabled.toggle() }

            ToolbarToggleButton(
                icon: webAudioMode ? "headphones.circle.fill" : "headphones.circle",
                label: "Web Audio",
                isActive: webAudioMode,
                activeColor: .indigo,
                isDisabled: false,
                compact: compact,
                help: webAudioMode ? "Web Audio: paste a URL to generate audio" : "Web Audio: turn article into audio"
            ) {
                webAudioMode.toggle()
                if webAudioMode {
                    inputFocused = true
                } else {
                    clearArticle()
                }
            }

            ToolbarToggleButton(
                icon: engine.boostEnabled ? "hare.fill" : "hare",
                label: "Boost",
                isActive: engine.boostEnabled,
                activeColor: .orange,
                isDisabled: false,
                compact: compact,
                help: engine.boostEnabled ? "Boost on: full speed" : "Boost off: reduced speed"
            ) { engine.boostEnabled.toggle() }

            // Context size badge — tap opens Settings
            Button(action: { showSettings = true }) {
                Text(engine.contextSizeOption.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Context: \(engine.contextSizeOption.label) tokens — click to change in Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            if let error = engine.loadingError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            } else {
                ProgressView()
                    .scaleEffect(0.8)
                Text(engine.loadingStatus)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var chatArea: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // VStack (not Lazy) so all items are always in the layout tree.
                    // LazyVStack defers off-screen rendering, which means
                    // proxy.scrollTo fires before new items exist in the layout and
                    // ends up at the wrong position — messages appear to disappear.
                    VStack(spacing: 0) {
                        if engine.messages.isEmpty {
                            emptyState
                        }
                        ForEach(engine.messages) { message in
                            MessageBubble(
                                message: message,
                                onImageTap: { img in expandedImage = img },
                                isStreaming: engine.isViewingGeneratingThread
                                    && engine.isGenerating
                                    && message.id == engine.messages.last?.id,
                                onSpeak: message.role == .assistant && !message.content.isEmpty
                                    ? {
                                        // Cached → play immediately.
                                        // Not cached → just synthesise; user taps Listen to play.
                                        if ttsEngine.cachedIds.contains(message.id) {
                                            ttsEngine.play(messageId: message.id, text: message.content)
                                        } else {
                                            ttsEngine.synthesizeBackground(
                                                messageId: message.id,
                                                text: message.content,
                                                autoPlay: false
                                            )
                                        }
                                    }
                                    : nil,
                                onStop: { ttsEngine.stopSpeaking() },
                                ttsIsStarting: ttsEngine.isStarting,
                                ttsIsSpeaking: ttsEngine.isSpeaking,
                                ttsPlayingMessageId: ttsEngine.speakingMessageId,
                                isBackgroundSynthesizing: ttsEngine.synthesizingIds.contains(message.id),
                                hasCachedAudio: ttsEngine.cachedIds.contains(message.id),
                                ttsIsPaused: ttsEngine.isPaused,
                                onPause: { ttsEngine.pause() },
                                onResume: { ttsEngine.resume() },
                                onSkipBack: { ttsEngine.skip(seconds: -10) },
                                onSkipForward: { ttsEngine.skip(seconds: 10) },
                                onExport: message.role == .assistant && ttsEngine.cachedIds.contains(message.id)
                                    ? {
                                        let name = String(message.content.prefix(50))
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                        let result = await ttsEngine.exportAudio(
                                            messageId: message.id,
                                            suggestedName: name.isEmpty ? "Pendragon Audio" : name
                                        )
                                        // Reveal the file in Finder on success
                                        if let url = result {
                                            await MainActor.run {
                                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                            }
                                        }
                                        return result != nil
                                    }
                                    : nil
                            )
                            .id(message.id)
                        }
                        // Status indicators only make sense when the user is watching
                        // the thread that's actually generating.
                        if engine.isThinking && engine.isViewingGeneratingThread {
                            ThinkingIndicator()
                                .id("thinking")
                        }
                        if engine.isSearching && engine.isViewingGeneratingThread {
                            SearchingIndicator()
                                .id("searching")
                        }
                        // Compacting indicator moved to toolbar (CompactTokenLabel)
                        // Spacer at the bottom — tall enough to scroll past
                        // current generation output without triggering auto-follow.
                        Color.clear.frame(height: 150).id("bottom_anchor")
                    }
                    .padding(.vertical, 12)
                }
                .onAppear {
                    NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        if event.scrollingDeltaY > 0 { userHasScrolledUp = true }
                        return event
                    }
                }
                .onChange(of: engine.messages.last?.content) { _ in
                    if !userHasScrolledUp {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom_anchor", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: engine.messages.count) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom_anchor", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: engine.currentThreadId) { _ in }
                // Pre-synthesise audio after each generation.
                // We look at the last 5 assistant messages each time isGenerating
                // goes false — this catches cases where two quick generations cause
                // SwiftUI to batch the intermediate false state and miss message 1.
                .onChange(of: engine.isGenerating) { generating in
                    guard !generating else { return }
                    let assistantMsgs = engine.messages
                        .filter { $0.role == .assistant && !$0.content.isEmpty }
                    let recent = assistantMsgs.suffix(5)
                    for (i, msg) in recent.enumerated() {
                        guard !ttsEngine.synthesizingIds.contains(msg.id),
                              !ttsEngine.cachedIds.contains(msg.id) else { continue }
                        let isNewest = i == recent.count - 1
                        ttsEngine.synthesizeBackground(
                            messageId: msg.id,
                            text: msg.content,
                            autoPlay: isNewest && ttsEngine.autoSpeak
                        )
                    }
                }
            }

            // Full-screen image expand overlay
            if let img = expandedImage {
                Color.black.opacity(0.75)
                    .ignoresSafeArea()
                    .onTapGesture { expandedImage = nil }
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(32)
                    .shadow(color: .black.opacity(0.6), radius: 24)
                    .onTapGesture { expandedImage = nil }
                    .transition(.opacity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 100)
            Image("PendragonAvatar")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .opacity(0.5)
            Text("Pendragon")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.secondary.opacity(0.6))
            Text("Your messages are processed entirely on-device.")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.4))
            Button(action: { showCapabilities = true }) {
                Label("See what Pendragon can do", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.yellow.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .liquidGlass(cornerRadius: 12, tint: Theme.surface.opacity(0.4))
            .padding(.top, 6)
        }
    }

    private var pendingMediaPreview: some View {
        HStack(alignment: .top, spacing: 12) {
            // Multiple image thumbnails — scrollable row, each with its own X
            if !engine.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(engine.pendingImages.indices, id: \.self) { idx in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: engine.pendingImages[idx])
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button(action: { engine.removeImage(at: idx) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                        .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                                }
                                .buttonStyle(.borderless)
                                .offset(x: 5, y: -5)
                            }
                        }
                        // + button to add more images (while under the cap)
                        if engine.canAddMoreImages {
                            Button(action: { engine.browseForImages() }) {
                                VStack(spacing: 3) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .light))
                                    Text("Add")
                                        .font(.system(size: 9))
                                }
                                .foregroundColor(.secondary.opacity(0.6))
                                .frame(width: 48, height: 72)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                )
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(maxHeight: 82)
            }

            if let duration = engine.pendingAudioDuration {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    Text(formatDuration(duration))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button(action: { engine.clearPendingAudio() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            if let pdfName = engine.pendingPDFName {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                    Text(pdfName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button(action: { engine.clearPendingPDF() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.5))
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Queue badge: visible when there are messages queued for this thread
            if let queueCount = queuedCountForCurrentThread, queueCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text(queueCount == 1 ? "1 message queued — will send after generation" :
                                          "\(queueCount) messages queued — will send after generation")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface.opacity(0.6))
            }

            // Background-generation notice: user is reading a different thread
            if engine.isGenerating && !engine.isViewingGeneratingThread {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.55)
                    Text("Generating in another conversation…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface.opacity(0.6))
            }

            if articlePhase != .none {
                articleChip
            }

            HStack(alignment: .center, spacing: 8) {
                Button(action: { browseForMedia() }) {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.borderless)
                .disabled(engine.isGenerating && engine.isViewingGeneratingThread)
                .help("Attach image or audio")

                TextField(webAudioMode ? "Paste a URL…" : "Message Pendragon…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit {
                        if !NSEvent.modifierFlags.contains(.shift) {
                            sendMessage()
                        }
                    }
                    .onAppear { inputFocused = true }

                // Mic button
                Button(action: {
                    if engine.isRecording {
                        engine.toggleRecording()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { sendMessage() }
                    } else {
                        engine.toggleRecording()
                    }
                }) {
                    if engine.isRecording {
                        RecordingIndicatorButton()
                    } else {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.5))
                            .opacity(0.5)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(engine.isGenerating && engine.isViewingGeneratingThread)
                .help(engine.isRecording ? "Stop & send" : "Record voice")

                // Send / Stop / Queue button
                Button(action: sendMessage) {
                    let isStop    = engine.isGenerating && engine.isViewingGeneratingThread
                    let isQueuing = engine.isGenerating && !engine.isViewingGeneratingThread && canSend
                    let iconName  = isStop    ? "stop.fill" :
                                   isQueuing  ? "clock.arrow.circlepath" :
                                               "arrow.up"
                    let bgColor: Color = isStop   ? .red.opacity(0.85) :
                                        isQueuing ? .orange.opacity(0.85) :
                                        canSend   ? .accentColor : .secondary.opacity(0.18)
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(canSend || isStop || isQueuing ? .white : .secondary.opacity(0.4))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(bgColor))
                        .shadow(
                            color: canSend ? Color.accentColor.opacity(0.35) : .clear,
                            radius: 6, x: 0, y: 2
                        )
                }
                .buttonStyle(.borderless)
                .disabled(!canSend && !(engine.isGenerating && engine.isViewingGeneratingThread))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            // Input card: system Liquid Glass — it supplies its own edge
            // highlights, so the previous hand-drawn border/inner-shadow
            // overlays are gone.
            .liquidGlass(cornerRadius: 14, tint: Theme.inputBg.opacity(0.45))
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .padding(.top, 8)
        }
    }

    // MARK: - Article-to-audio

    @ViewBuilder
    private var articleChip: some View {
        HStack(spacing: 8) {
            switch articlePhase {
            case .loading:
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Fetching article…")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            case .ready:
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundColor(.indigo)
                if let a = pendingArticle {
                    Text("\(a.wordCount) words · ~\(a.estimatedMinutes) min audio")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Button(action: startArticleSynth) {
                    HStack(spacing: 4) {
                        Image(systemName: "headphones").font(.system(size: 10))
                        Text("Generate Audio").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.indigo)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.indigo.opacity(0.12)))
                }
                .buttonStyle(.borderless)
                .disabled(!ttsEngine.isReady)
                Button(action: clearArticle) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.borderless)
            case .synthesizing:
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Generating audio…")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button("Cancel") {
                    articleSynthTask?.cancel()
                    articlePhase = .ready
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func handlePastedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isURL = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
                    && !trimmed.contains(" ") && !trimmed.contains("\n")
        // Fetch article when Web Audio mode is on, or when pasting a bare URL into an empty field
        if isURL && (webAudioMode || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            fetchArticle(url: trimmed)
        } else {
            inputText = (inputText.isEmpty ? "" : inputText + "\n\n") + text
        }
    }

    private func fetchArticle(url: String) {
        articleFetchTask?.cancel()
        pendingArticle = nil
        articlePhase   = .loading
        inputText      = ""

        articleFetchTask = Task {
            do {
                let article = try await ArticleReader.fetch(url)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    pendingArticle = article
                    inputText      = article.title
                    articlePhase   = .ready
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    articlePhase = .none
                    // Fall back to pasting the URL as plain text
                    inputText = url
                }
            }
        }
    }

    private func startArticleSynth() {
        guard let article = pendingArticle else { return }
        articleSynthTask?.cancel()
        articlePhase = .synthesizing

        articleSynthTask = Task {
            if let data = await ttsEngine.synthesizeRaw(text: article.body) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    ttsEngine.playRaw(data)
                    clearArticle()
                }
            } else {
                guard !Task.isCancelled else { return }
                await MainActor.run { articlePhase = .ready }
            }
        }
    }

    private func clearArticle() {
        articleFetchTask?.cancel()
        articleSynthTask?.cancel()
        let wasTitle = pendingArticle?.title
        pendingArticle = nil
        articlePhase   = .none
        webAudioMode   = false
        if let t = wasTitle, inputText == t { inputText = "" }
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = !engine.pendingImages.isEmpty
        let hasAudio = engine.pendingAudioSamples != nil
        let hasPDF = engine.pendingPDFText != nil
        return (hasText || hasImage || hasAudio || hasPDF) && !engine.isRecording && !engine.isTranslating
    }

    /// Number of queued messages for the thread the user is currently viewing
    private var queuedCountForCurrentThread: Int? {
        guard let tid = engine.currentThreadId else { return nil }
        let count = engine.messageQueue.filter { $0.threadId == tid }.count
        return count > 0 ? count : nil
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stop button: only if viewing the generating thread with an empty input
        if engine.isGenerating && engine.isViewingGeneratingThread &&
           text.isEmpty && engine.pendingImages.isEmpty && engine.pendingAudioSamples == nil {
            engine.stopGenerating()
            return
        }
        guard !text.isEmpty || !engine.pendingImages.isEmpty || engine.pendingAudioSamples != nil else { return }
        inputText = ""
        engine.send(text)   // engine.send() handles queuing internally
    }

    private func browseForMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .audio, .wav, .mp3, .pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select images, audio, or a PDF file"
        guard panel.runModal() == .OK else { return }
        let audioExtensions = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "aiff", "caf"]
        for url in panel.urls {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                engine.attachPDF(from: url)
            } else if audioExtensions.contains(ext) {
                engine.attachAudioFile(from: url)
            } else {
                engine.attachImage(from: url)
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Transport icon button (with hover highlight)

private struct TransportIconButton: View {
    let systemName: String
    var color: Color = .secondary
    var activeColor: Color? = nil     // if set, use this color when hovered
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundColor(hovered ? (activeColor ?? color).opacity(0.9) : color.opacity(0.55))
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovered ? Color.secondary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    var onImageTap: ((NSImage) -> Void)? = nil
    /// True when this specific message is the one currently being streamed
    var isStreaming: Bool = false
    /// Called when the user taps the play button; nil hides the button
    var onSpeak: (() -> Void)? = nil
    /// Called when the user taps Stop while this bubble is speaking
    var onStop: (() -> Void)? = nil
    /// True while the TTS model is loading (for spinner)
    var ttsIsStarting: Bool = false
    /// True while any TTS audio is playing (used to reset per-bubble spinner)
    var ttsIsSpeaking: Bool = false
    /// The message ID that is currently playing audio (nil = nothing playing)
    var ttsPlayingMessageId: UUID? = nil
    /// True while audio is being pre-synthesised for this specific message
    var isBackgroundSynthesizing: Bool = false
    /// True when this message's audio is cached and ready for instant playback
    var hasCachedAudio: Bool = false
    /// True while the current playback is paused (only meaningful when isSpeakingNow)
    var ttsIsPaused: Bool = false
    /// Pause the current playback
    var onPause: (() -> Void)? = nil
    /// Resume after pause
    var onResume: (() -> Void)? = nil
    /// Skip backward 10 seconds
    var onSkipBack: (() -> Void)? = nil
    /// Skip forward 10 seconds
    var onSkipForward: (() -> Void)? = nil
    /// Export cached audio to Downloads. Returns true on success.
    var onExport: (() async -> Bool)? = nil

    /// How many characters have been fully revealed (opacity 1.0)
    @State private var revealedLength: Int = 0
    /// Live target – stored in @State so the Task loop can read the current
    /// value rather than a stale copy of the captured `message` struct.
    @State private var targetLength: Int = 0
    /// Whether the reveal loop is currently running
    @State private var isRevealLooping: Bool = false
    /// Flashes true briefly after copying the message output
    @State private var outputCopied = false
    /// Hover state for the Copy button
    @State private var copyHovered = false
    /// Hover state for the Listen button
    @State private var listenHovered = false
    /// Drives the animated waveform bars while Speaking
    @State private var wavePhase: Double = 0
    /// Flash state for the Export button
    private enum ExportFlash: Equatable { case idle, saving, saved, failed }
    @State private var exportFlash: ExportFlash = .idle
    /// Hover state for transport buttons that aren't TransportIconButton
    @State private var stopHovered = false
    @State private var exportHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .assistant {
                Image("PendragonAvatar")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(
                            isStreaming
                                ? Color.accentColor.opacity(0.6)
                                : Color.white.opacity(0.08),
                            lineWidth: isStreaming ? 1.5 : 1
                        )
                    )
                    .shadow(
                        color: isStreaming ? Color.accentColor.opacity(0.4) : .clear,
                        radius: 7, x: 0, y: 0
                    )
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if !message.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(message.images.indices, id: \.self) { idx in
                                let img = message.images[idx]
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: message.images.count == 1 ? 300 : 180,
                                           maxHeight: message.images.count == 1 ? 200 : 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                    .onTapGesture { onImageTap?(img) }
                                    .help("Click to expand")
                            }
                        }
                    }
                }
                if message.hasAudio {
                    AudioBadge(duration: message.audioDuration)
                }
                if let pdfName = message.pdfName {
                    PDFCard(name: pdfName, thumbnail: message.pdfThumbnail)
                }
                if !message.content.isEmpty {
                    // Only render the revealed portion + the 15-char shadow zone
                    let fadeWidth = 15
                    let visEnd   = min(message.content.count, revealedLength + fadeWidth)
                    let vis      = String(message.content.prefix(visEnd))
                    MarkdownContentView(
                        content: vis,
                        isUser: message.role == .user,
                        stableLength: min(revealedLength, vis.count),
                        isStreaming: isStreaming
                    )
                    .onAppear {
                        // Pre-existing / already-complete messages: show all at once.
                        // For in-progress messages the loop will drive revealedLength.
                        targetLength = message.content.count
                        revealedLength = message.content.count
                    }
                    .onChange(of: message.content) { newContent in
                        // Keep the live target up to date, then (re)start the loop.
                        targetLength = newContent.count
                        ensureRevealRunning()
                    }
                }
                // Visualization badge + collapsible code dropdown
                if message.hasVisualization {
                    ThreeJSCodeDropdown(code: message.visualizationCode)
                        .padding(.top, 2)
                }
                // Source links
                if !message.sourceURLs.isEmpty {
                    SourceLinksView(sources: message.sourceURLs, isSearch: message.usedWebSearch)
                        .padding(.top, 4)
                }

                // Action row — copy + play buttons for completed assistant messages
                if message.role == .assistant && !message.content.isEmpty && !isStreaming {
                    HStack(spacing: 6) {
                        // ── Copy button ──
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            outputCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { outputCopied = false }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: outputCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10))
                                Text(outputCopied ? "Copied!" : "Copy")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(
                                outputCopied
                                    ? .green.opacity(0.9)
                                    : copyHovered ? .secondary.opacity(0.85) : .secondary.opacity(0.5)
                            )
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(
                                        outputCopied
                                            ? Color.green.opacity(0.1)
                                            : copyHovered ? Theme.surface.opacity(1.8) : Theme.surface
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { copyHovered = $0 }
                        .help("Copy message to clipboard")

                        // ── Listen / Preparing / Speaking button ──
                        if let onSpeak {
                            // This bubble's audio is actively playing
                            let isSpeakingNow  = ttsPlayingMessageId == message.id && ttsIsSpeaking
                            // User tapped Listen but TTS model is still loading
                            let isModelLoading = ttsPlayingMessageId == message.id && !ttsIsSpeaking && ttsIsStarting
                            // Background synthesis is running for this message
                            let isPreparing    = isBackgroundSynthesizing && !isSpeakingNow && !isModelLoading

                            if isSpeakingNow {
                                // ── Speaking / Paused state: transport controls ──
                                HStack(spacing: 2) {
                                    // Skip back 10 s
                                    TransportIconButton(systemName: "gobackward.10") { onSkipBack?() }
                                        .help("Back 10 seconds")

                                    // Pause / Resume
                                    TransportIconButton(
                                        systemName: ttsIsPaused ? "play.fill" : "pause.fill",
                                        color: ttsIsPaused ? .accentColor : .secondary,
                                        activeColor: ttsIsPaused ? .accentColor : .secondary
                                    ) { ttsIsPaused ? onResume?() : onPause?() }
                                        .help(ttsIsPaused ? "Resume" : "Pause")

                                    // Skip forward 10 s
                                    TransportIconButton(systemName: "goforward.10") { onSkipForward?() }
                                        .help("Forward 10 seconds")

                                    // Status indicator
                                    if ttsIsPaused {
                                        Text("Paused")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.secondary.opacity(0.5))
                                            .padding(.leading, 2)
                                    } else {
                                        HStack(spacing: 2) {
                                            ForEach(0..<4, id: \.self) { i in
                                                RoundedRectangle(cornerRadius: 1)
                                                    .fill(Color.green.opacity(0.75))
                                                    .frame(width: 2.5,
                                                           height: 4 + 6 * abs(sin(wavePhase + Double(i) * 0.9)))
                                                    .animation(
                                                        .easeInOut(duration: 0.35)
                                                        .repeatForever(autoreverses: true)
                                                        .delay(Double(i) * 0.08),
                                                        value: wavePhase
                                                    )
                                            }
                                        }
                                        .frame(height: 14)
                                        .onAppear { wavePhase = .pi }
                                        .padding(.leading, 2)

                                        Text("Speaking…")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.green.opacity(0.8))
                                    }

                                    // Stop (resets to beginning on next play)
                                    Button(action: { onStop?() }) {
                                        Text("Stop")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(stopHovered ? .secondary.opacity(0.85) : .secondary.opacity(0.55))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .fill(stopHovered ? Theme.surface.opacity(2.0) : Theme.surface)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { stopHovered = $0 }
                                }
                            } else {
                                // ── Idle / Preparing / Loading / Ready state ──
                                // Only disable while the TTS model itself is loading.
                                // During background synthesis (isPreparing) the button stays
                                // tappable — tapping marks the audio to play as soon as it's ready.
                                let isDisabled = isModelLoading
                                Button(action: { onSpeak() }) {
                                    HStack(spacing: 4) {
                                        if isModelLoading || isPreparing {
                                            ProgressView()
                                                .progressViewStyle(.circular)
                                                .scaleEffect(0.55)
                                                .frame(width: 12, height: 12)
                                        } else if hasCachedAudio {
                                            // Ready indicator: filled headphones with a dot
                                            ZStack(alignment: .topTrailing) {
                                                Image(systemName: "headphones")
                                                    .font(.system(size: 10))
                                                Circle()
                                                    .fill(Color.green.opacity(0.85))
                                                    .frame(width: 5, height: 5)
                                                    .offset(x: 2, y: -1)
                                            }
                                            .frame(width: 14, height: 12)
                                        } else {
                                            Image(systemName: "headphones")
                                                .font(.system(size: 10))
                                        }
                                        if isPreparing {
                                            Text("Preparing…")
                                                .font(.system(size: 10, weight: .medium))
                                        } else if isModelLoading {
                                            Text("Loading…")
                                                .font(.system(size: 10, weight: .medium))
                                        } else if hasCachedAudio {
                                            Text("Listen")
                                                .font(.system(size: 10, weight: .medium))
                                        } else {
                                            Text("Generate audio")
                                                .font(.system(size: 10, weight: .medium))
                                        }
                                    }
                                    .foregroundColor(
                                        isDisabled
                                            ? .secondary.opacity(0.4)
                                            : hasCachedAudio
                                                ? (listenHovered ? Color.green.opacity(0.9) : Color.green.opacity(0.65))
                                                : listenHovered ? .secondary.opacity(0.85) : .secondary.opacity(0.5)
                                    )
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(
                                                hasCachedAudio && listenHovered && !isDisabled
                                                    ? Color.green.opacity(0.08)
                                                    : listenHovered && !isDisabled ? Theme.surface.opacity(1.8) : Theme.surface
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isDisabled)
                                .onHover { listenHovered = $0 }
                                .help(
                                    isPreparing    ? "Generating audio…" :
                                    isModelLoading ? "Loading voice model…" :
                                    hasCachedAudio ? "Audio ready — tap to listen" :
                                    "Generate audio for this message"
                                )
                            }

                            // ── Export button — visible whenever audio is ready ──
                            if hasCachedAudio, let onExport {
                                Button {
                                    guard exportFlash == .idle else { return }
                                    exportFlash = .saving
                                    Task {
                                        let ok = await onExport()
                                        exportFlash = ok ? .saved : .failed
                                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                                        exportFlash = .idle
                                    }
                                } label: {
                                    Group {
                                        switch exportFlash {
                                        case .idle:
                                            Image(systemName: "square.and.arrow.down")
                                                .font(.system(size: 10))
                                        case .saving:
                                            ProgressView()
                                                .progressViewStyle(.circular)
                                                .scaleEffect(0.5)
                                                .frame(width: 10, height: 10)
                                        case .saved:
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10))
                                        case .failed:
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10))
                                        }
                                    }
                                    .foregroundColor(
                                        exportFlash == .saved  ? .green.opacity(0.85) :
                                        exportFlash == .failed ? .red.opacity(0.75)   :
                                        exportHovered          ? .secondary.opacity(0.85) :
                                                                 .secondary.opacity(0.5)
                                    )
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(exportHovered && exportFlash == .idle
                                                  ? Theme.surface.opacity(2.0) : Theme.surface)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(exportFlash == .saving)
                                .onHover { exportHovered = $0 }
                                .help(
                                    exportFlash == .saving ? "Exporting…" :
                                    exportFlash == .saved  ? "Saved to Downloads!" :
                                    exportFlash == .failed ? "Export failed" :
                                    "Export audio to Downloads"
                                )
                            }
                        }
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .padding(.top, 1)
                }

            }
            .frame(maxWidth: 560, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Circle()
                    .fill(Theme.userBubble)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.accentColor)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// Advances revealedLength toward targetLength.
    ///
    /// Uses @State targetLength so the loop always sees the latest length even
    /// as tokens stream in (avoids the value-capture problem with `message`).
    ///
    /// The loop stays alive for ~750 ms after catching up so it can smoothly
    /// pick up the next token without a restart-jitter "pulse". Reveal speed
    /// scales with the buffer: fast when many chars are queued (boost mode),
    /// slow (~30fps) when the buffer is small so the shadow lingers instead of
    /// snapping away between tokens (non-boost mode).
    private func ensureRevealRunning() {
        guard !isRevealLooping else { return }
        isRevealLooping = true
        Task { @MainActor in
            var staleTicks = 0
            while staleTicks < 45 {          // 45 × 16.7 ms ≈ 750 ms idle budget
                if revealedLength < targetLength {
                    staleTicks = 0
                    let buffer = targetLength - revealedLength
                    let step: Int   = buffer > 60 ? 3 : (buffer > 30 ? 2 : 1)
                    // Large buffer → full 60 fps; small buffer → 30 fps so the
                    // shadow doesn't vanish instantly between slow tokens.
                    let ns: UInt64  = buffer > 30 ? 16_666_667 : 33_333_333
                    revealedLength  = min(revealedLength + step, targetLength)
                    try? await Task.sleep(nanoseconds: ns)
                } else {
                    staleTicks += 1
                    try? await Task.sleep(nanoseconds: 16_666_667)
                }
            }
            isRevealLooping = false
        }
    }
}

// MARK: - Small Components

struct PDFCard: View {
    let name: String
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 64)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 48, height: 64)
                    .overlay(
                        Image(systemName: "doc.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.red)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Text("PDF Document")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.divider, lineWidth: 1))
    }
}

struct SourceLinksView: View {
    let sources: [(title: String, url: String)]
    let isSearch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: isSearch ? "magnifyingglass" : "globe")
                    .font(.system(size: 9))
                Text(isSearch ? "Sources" : "Source")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(Theme.textSecondary)

            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9))
                            Text(cleanTitle(source.title))
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .foregroundColor(.accentColor.opacity(0.85))
                    }
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
        }
    }

    private func cleanTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Link" : t
    }
}

struct RecordingIndicatorButton: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Pulsing outer ring
            Circle()
                .stroke(Color.red.opacity(0.4), lineWidth: 2)
                .frame(width: 28, height: 28)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .opacity(isPulsing ? 0.0 : 0.6)

            Image(systemName: "record.circle")
                .font(.system(size: 24))
                .foregroundColor(.red)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

struct AudioBadge: View {
    let duration: TimeInterval?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 12))
            Text("Voice")
                .font(.system(size: 12, weight: .medium))
            if let duration {
                Text(formatDuration(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// Compact toolbar label: shows token count normally, flashes "Compactifying…" when busy.
struct CompactTokenLabel: View {
    let tokenCount: Int32
    let isCompacting: Bool

    @State private var flashVisible = true

    private var formattedTokens: String {
        tokenCount >= 1000
            ? String(format: "%.1fK", Double(tokenCount) / 1000.0)
            : "\(tokenCount)"
    }

    var body: some View {
        Group {
            if isCompacting {
                Text(flashVisible ? "Compactifying…" : "")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange.opacity(0.8))
                    .onAppear {
                        // Simple 0.7 s on / 0.4 s off flash loop
                        flashVisible = true
                        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { t in
                            guard isCompacting else { t.invalidate(); return }
                            flashVisible.toggle()
                        }
                    }
            } else {
                Text(formattedTokens)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.55))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isCompacting ? Color.orange.opacity(0.08) : Theme.surface)
        )
        .help(isCompacting
              ? "Compactifying conversation…"
              : "\(tokenCount) tokens used")
        .animation(.easeInOut(duration: 0.2), value: isCompacting)
    }
}

// MARK: - Status Indicators

// MARK: - Toolbar toggle button with hover state

struct ToolbarToggleButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let activeColor: Color
    let isDisabled: Bool
    var compact: Bool = false
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12))
                if !compact {
                    Text(label).font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                          ? activeColor.opacity(0.18)
                          : isHovering ? activeColor.opacity(0.10) : Color.secondary.opacity(0.08))
            )
            .foregroundColor(
                isActive
                    ? activeColor
                    : isHovering ? activeColor.opacity(0.75) : .secondary
            )
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

struct ThinkingIndicator: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        HStack(spacing: 12) {
            Image("PendragonAvatar")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(Circle())

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                Text("Thinking...")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.purple.opacity(0.7))
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

struct SearchingIndicator: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        HStack(spacing: 12) {
            Image("PendragonAvatar")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(Circle())

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                Text("Searching the web...")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.blue.opacity(0.7))
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

struct CompactingIndicator: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        HStack(spacing: 12) {
            Image("PendragonAvatar")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(Circle())

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                Text("Compacting memory...")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.green.opacity(0.7))
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

struct SpeakingIndicator: View {
    let onStop: () -> Void
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Image("PendragonAvatar")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(Circle())

            HStack(spacing: 6) {
                // Animated waveform bars
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.green.opacity(0.7))
                            .frame(width: 3,
                                   height: 6 + 8 * abs(sin(phase + Double(i) * 0.8)))
                            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.1), value: phase)
                    }
                }
                Text("Speaking...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.green.opacity(0.8))

                Button(action: onStop) {
                    Text("Stop")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onAppear { phase = .pi }
    }
}

// MARK: - Markdown Rendering

enum MarkdownBlock {
    case text(String)
    case list(items: [(bullet: String, text: String)]) // bullet = "•" or "1." etc.
    case codeBlock(language: String, code: String)
    case horizontalRule
    case blockquote(String)
    case table(headers: [String], rows: [[String]])
    case latex(String)
}

/// Small animated dot shown next to the thread title when it is generating in background
private struct GeneratingDot: View {
    @State private var opacity: Double = 0.3
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }
    }
}

struct MarkdownContentView: View {
    let content: String
    let isUser: Bool
    /// Characters before this index are fully opaque; beyond it they fade out
    var stableLength: Int = Int.max
    /// True when this content belongs to the message currently being streamed.
    /// Controls whether a threejs block shows VisualizationGeneratingView or is skipped.
    var isStreaming: Bool = false

    /// Width of the shadow gradient (characters)
    private let fadeWidth = 15
    /// How many tail characters are in the fade zone
    private var tailLen: Int { max(0, content.count - stableLength) }

    var body: some View {
        let blocks = parseBlocks()
        let blockCount = blocks.count
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { (index, block) in
                let isLastBlock = index == blockCount - 1
                switch block {
                case .text(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if isLastBlock && tailLen > 0 {
                            fadingText(text)
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                        } else {
                            Text(inlineMarkdown(text))
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                        }
                    }
                case .list(let items):
                    // Grid gives each column a proper fixed width so the text column
                    // wraps independently — continuation lines align with the first
                    // character of the first line, not the bullet.
                    Grid(alignment: .topLeading, horizontalSpacing: 6, verticalSpacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            GridRow(alignment: .top) {
                                Text(item.bullet)
                                    .font(.system(size: 14))
                                    .gridColumnAlignment(.leading)
                                    .fixedSize()
                                if isLastBlock && tailLen > 0 {
                                    fadingText(item.text)
                                        .gridColumnAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(inlineMarkdown(item.text))
                                        .font(.system(size: 14))
                                        .textSelection(.enabled)
                                        .gridColumnAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                case .codeBlock(let language, let code):
                    if language == "threejs" {
                        // Spinner only while actively streaming; skip for completed messages
                        // (completed messages have the block extracted + ThreeJSCodeDropdown shown)
                        if isStreaming {
                            VisualizationGeneratingView()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            if !language.isEmpty {
                                Text(language)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                            }
                            Text(code)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, language.isEmpty ? 8 : 4)
                                .padding(.bottom, language.isEmpty ? 0 : 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.codeBg))
                    }
                case .horizontalRule:
                    Divider()
                        .padding(.vertical, 4)
                case .blockquote(let text):
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                        Text(inlineMarkdown(text))
                            .font(.system(size: 14))
                            .italic()
                            .foregroundColor(.secondary)
                            .padding(.leading, 10)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                case .table(let headers, let rows):
                    TableBlockView(headers: headers, rows: rows)
                case .latex(let expr):
                    LaTeXBlockView(latex: expr)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Bubbles use system Liquid Glass (own edge lighting — no manual borders).
        .liquidGlass(cornerRadius: 16,
                     tint: isUser ? Theme.userBubble : Theme.assistantBubble)
    }

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = content.components(separatedBy: "\n")
        var currentText: [String] = []
        var inCodeBlock = false
        var codeLanguage = ""
        var codeLines: [String] = []
        var tableHeaders: [String] = []
        var tableRows: [[String]] = []
        var inTable = false
        var inLatexBlock = false
        var latexLines: [String] = []
        var listItems: [(bullet: String, text: String)] = []

        func flushText() {
            if !currentText.isEmpty {
                blocks.append(.text(preprocessInline(currentText.joined(separator: "\n"))))
                currentText = []
            }
        }

        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(items: listItems))
                listItems = []
            }
        }

        func flushTable() {
            if inTable && !tableHeaders.isEmpty {
                blocks.append(.table(headers: tableHeaders, rows: tableRows))
                tableHeaders = []
                tableRows = []
                inTable = false
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // LaTeX block: $$...$$ spanning one or more lines
            if inLatexBlock {
                if trimmed.hasSuffix("$$") {
                    let lastLine = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces)
                    if !lastLine.isEmpty { latexLines.append(lastLine) }
                    blocks.append(.latex(latexLines.joined(separator: "\n")))
                    latexLines = []
                    inLatexBlock = false
                } else {
                    latexLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("$$") {
                let afterOpen = String(trimmed.dropFirst(2))
                // Single-line: $$...$$
                if afterOpen.hasSuffix("$$") && afterOpen.count > 2 {
                    let expr = String(afterOpen.dropLast(2)).trimmingCharacters(in: .whitespaces)
                    flushText()
                    flushTable()
                    blocks.append(.latex(expr))
                    continue
                }
                // Multi-line start
                flushText()
                flushTable()
                inLatexBlock = true
                let rest = afterOpen.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { latexLines.append(rest) }
                continue
            }

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.codeBlock(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines = []
                    codeLanguage = ""
                    inCodeBlock = false
                } else {
                    flushText()
                    flushTable()
                    inCodeBlock = true
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushText()
                flushTable()
                blocks.append(.horizontalRule)
                continue
            }

            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                let cells = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }

                if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" }) && !$0.isEmpty }) {
                    continue
                }

                if !inTable {
                    flushText()
                    inTable = true
                    tableHeaders = cells
                } else {
                    tableRows.append(cells)
                }
                continue
            } else if inTable {
                flushTable()
            }

            if trimmed.hasPrefix("> ") {
                flushText()
                flushList()
                let quoteText = String(trimmed.dropFirst(2))
                if case .blockquote(let prev) = blocks.last {
                    blocks[blocks.count - 1] = .blockquote(prev + "\n" + quoteText)
                } else {
                    blocks.append(.blockquote(quoteText))
                }
                continue
            }

            // Unordered list: lines starting with "- " or "* "
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushText()
                flushTable()
                let text = String(trimmed.dropFirst(2))
                listItems.append((bullet: "•", text: text))
                continue
            }

            // Ordered list: lines starting with "N. " (digit(s) + dot + space)
            let orderedPattern = #"^(\d+)\.\s(.+)"#
            if let regex = try? NSRegularExpression(pattern: orderedPattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let numRange = Range(match.range(at: 1), in: trimmed),
               let txtRange = Range(match.range(at: 2), in: trimmed) {
                flushText()
                flushTable()
                listItems.append((bullet: "\(trimmed[numRange]).", text: String(trimmed[txtRange])))
                continue
            }

            // Continuation of a list item: an indented (2+ spaces) non-blank line
            // that immediately follows a list item.  Append it to the last item
            // instead of flushing — this keeps wrapped bullet text in one Text view
            // so it aligns correctly.
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            if !listItems.isEmpty && leadingSpaces >= 2 && !trimmed.isEmpty {
                listItems[listItems.count - 1].text += " " + trimmed
                continue
            }

            // Non-list line — flush any open list so it doesn't bleed into text
            if !listItems.isEmpty && !trimmed.isEmpty {
                flushList()
            }

            currentText.append(line)
        }

        if inCodeBlock {
            blocks.append(.codeBlock(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }
        flushTable()
        flushList()
        flushText()

        return blocks
    }

    private func preprocessInline(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var processed: [String] = []
        for line in lines {
            var l = line
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            // Heading conversion — handles h1–h5 (all map to bold text)
            if trimmed.hasPrefix("##### ") {
                l = "**" + String(trimmed.dropFirst(6)) + "**"
            } else if trimmed.hasPrefix("#### ") {
                l = "**" + String(trimmed.dropFirst(5)) + "**"
            } else if trimmed.hasPrefix("### ") {
                l = "**" + String(trimmed.dropFirst(4)) + "**"
            } else if trimmed.hasPrefix("## ") {
                l = "**" + String(trimmed.dropFirst(3)) + "**"
            } else if trimmed.hasPrefix("# ") {
                l = "**" + String(trimmed.dropFirst(2)) + "**"
            }
            // Convert inline $...$ LaTeX to Unicode approximation
            l = Self.convertInlineLatex(l)
            processed.append(l)
        }
        return processed.joined(separator: "\n")
    }

    private static func convertInlineLatex(_ text: String) -> String {
        var result = text
        // Replace $...$ with Unicode approximations
        let pattern = #"\$([^$]+)\$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        // Process in reverse to preserve ranges
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let innerRange = Range(match.range(at: 1), in: result) else { continue }
            let latex = String(result[innerRange])
            let unicode = latexToUnicode(latex)
            result.replaceSubrange(fullRange, with: unicode)
        }
        return result
    }

    private static func latexToUnicode(_ latex: String) -> String {
        var s = latex
        // Bold math: \mathbf{X}
        let mathbfPattern = #"\\mathbf\{([^}]+)\}"#
        if let regex = try? NSRegularExpression(pattern: mathbfPattern) {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: s),
                   let innerRange = Range(match.range(at: 1), in: s) {
                    let inner = String(s[innerRange])
                    let bold = inner.unicodeScalars.map { scalar -> String in
                        if scalar.value >= 0x41 && scalar.value <= 0x5A { // A-Z
                            return String(UnicodeScalar(0x1D400 + scalar.value - 0x41)!)
                        } else if scalar.value >= 0x61 && scalar.value <= 0x7A { // a-z
                            return String(UnicodeScalar(0x1D41A + scalar.value - 0x61)!)
                        }
                        return String(scalar)
                    }.joined()
                    s.replaceSubrange(fullRange, with: bold)
                }
            }
        }
        // Common Greek letters
        let greekMap: [(String, String)] = [
            ("\\alpha", "\u{03B1}"), ("\\beta", "\u{03B2}"), ("\\gamma", "\u{03B3}"),
            ("\\delta", "\u{03B4}"), ("\\epsilon", "\u{03B5}"), ("\\varepsilon", "\u{03B5}"),
            ("\\zeta", "\u{03B6}"), ("\\eta", "\u{03B7}"), ("\\theta", "\u{03B8}"),
            ("\\iota", "\u{03B9}"), ("\\kappa", "\u{03BA}"), ("\\lambda", "\u{03BB}"),
            ("\\mu", "\u{03BC}"), ("\\nu", "\u{03BD}"), ("\\xi", "\u{03BE}"),
            ("\\pi", "\u{03C0}"), ("\\rho", "\u{03C1}"), ("\\sigma", "\u{03C3}"),
            ("\\tau", "\u{03C4}"), ("\\upsilon", "\u{03C5}"), ("\\phi", "\u{03C6}"),
            ("\\chi", "\u{03C7}"), ("\\psi", "\u{03C8}"), ("\\omega", "\u{03C9}"),
            ("\\Gamma", "\u{0393}"), ("\\Delta", "\u{0394}"), ("\\Theta", "\u{0398}"),
            ("\\Lambda", "\u{039B}"), ("\\Xi", "\u{039E}"), ("\\Pi", "\u{03A0}"),
            ("\\Sigma", "\u{03A3}"), ("\\Phi", "\u{03A6}"), ("\\Psi", "\u{03A8}"),
            ("\\Omega", "\u{03A9}"),
        ]
        // Common math symbols
        let symbolMap: [(String, String)] = [
            ("\\nabla", "\u{2207}"), ("\\partial", "\u{2202}"), ("\\infty", "\u{221E}"),
            ("\\cdot", "\u{22C5}"), ("\\times", "\u{00D7}"), ("\\pm", "\u{00B1}"),
            ("\\leq", "\u{2264}"), ("\\geq", "\u{2265}"), ("\\neq", "\u{2260}"),
            ("\\approx", "\u{2248}"), ("\\equiv", "\u{2261}"), ("\\sum", "\u{2211}"),
            ("\\prod", "\u{220F}"), ("\\int", "\u{222B}"), ("\\sqrt", "\u{221A}"),
            ("\\leftarrow", "\u{2190}"), ("\\rightarrow", "\u{2192}"),
            ("\\Leftarrow", "\u{21D0}"), ("\\Rightarrow", "\u{21D2}"),
        ]
        // Sort by length descending to avoid partial matches (e.g. \mu before \mu_0)
        for (cmd, uni) in (greekMap + symbolMap).sorted(by: { $0.0.count > $1.0.count }) {
            s = s.replacingOccurrences(of: cmd, with: uni)
        }
        // Subscripts: _{0} or _0
        let subMap: [Character: String] = [
            "0": "\u{2080}", "1": "\u{2081}", "2": "\u{2082}", "3": "\u{2083}",
            "4": "\u{2084}", "5": "\u{2085}", "6": "\u{2086}", "7": "\u{2087}",
            "8": "\u{2088}", "9": "\u{2089}",
        ]
        // _{...} subscripts
        if let subRegex = try? NSRegularExpression(pattern: #"_\{([^}]+)\}"#) {
            let matches = subRegex.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: s),
                   let innerRange = Range(match.range(at: 1), in: s) {
                    let inner = String(s[innerRange])
                    let sub = inner.map { subMap[$0].map { String($0) } ?? String($0) }.joined()
                    s.replaceSubrange(fullRange, with: sub)
                }
            }
        }
        // Single char subscripts: _X
        if let subRegex2 = try? NSRegularExpression(pattern: #"_([0-9])"#) {
            let matches = subRegex2.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: s),
                   let innerRange = Range(match.range(at: 1), in: s) {
                    let ch = s[innerRange].first!
                    let sub = subMap[ch] ?? String(ch)
                    s.replaceSubrange(fullRange, with: sub)
                }
            }
        }
        // Clean up remaining braces and \frac etc that we can't easily render
        s = s.replacingOccurrences(of: "\\frac", with: "")
        s = s.replacingOccurrences(of: "\\left(", with: "(")
        s = s.replacingOccurrences(of: "\\right)", with: ")")
        s = s.replacingOccurrences(of: "\\left[", with: "[")
        s = s.replacingOccurrences(of: "\\right]", with: "]")
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")
        s = s.replacingOccurrences(of: "\\", with: "")
        return s
    }

    /// Builds a Text with the stable prefix fully opaque and the fade tail
    /// shading from opaque → transparent, left to right.
    /// Must live outside @ViewBuilder so the imperative loop compiles.
    private func fadingText(_ text: String) -> Text {
        let tailInBlock = min(tailLen, text.count)
        let sp = String(text.dropLast(tailInBlock))   // stable prefix
        let sf = String(text.suffix(tailInBlock))     // fade suffix
        let sfCount = Double(max(sf.count, 1))
        var t: Text = Text(inlineMarkdown(sp))
        for (i, char) in sf.enumerated() {
            let opacity = 1.0 - Double(i) / sfCount
            t = t + Text(String(char)).foregroundColor(.primary.opacity(opacity))
        }
        return t.font(.system(size: 14))
    }

    private func inlineMarkdown(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return attributed
        }
        return AttributedString(string)
    }
}

struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    @State private var copied = false
    @State private var isHovering = false

    /// Parse inline markdown (bold, italic, code) into an AttributedString.
    private func inlineMarkdown(_ text: String) -> AttributedString {
        // Strip surrounding ** or * that the model sometimes wraps headers in
        let stripped = text
            .trimmingCharacters(in: .whitespaces)
        if let attr = try? AttributedString(markdown: stripped,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(stripped)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                // ── Header row ──────────────────────────────────────────────
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(inlineMarkdown(header))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color.secondary.opacity(0.12))

                Divider()

                // ── Data rows ────────────────────────────────────────────────
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        let padded = row + Array(repeating: "", count: max(0, headers.count - row.count))
                        ForEach(Array(padded.prefix(headers.count).enumerated()), id: \.offset) { colIdx, cell in
                            Text(inlineMarkdown(cell))
                                .font(.system(size: 12))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(colIdx == 0 ? Color.secondary.opacity(0.04) : Color.clear)
                        }
                    }
                    .background(rowIdx % 2 == 1 ? Color.secondary.opacity(0.03) : Color.clear)
                    if rowIdx < rows.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Copy button — visible on hover
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tableAsMarkdown(), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9))
                    Text(copied ? "Copied!" : "Copy").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(copied ? .green.opacity(0.9) : .secondary.opacity(0.7))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || copied ? 1 : 0)
            .padding(4)
        }
        .onHover { h in isHovering = h }
    }

    private func tableAsMarkdown() -> String {
        var lines: [String] = []
        lines.append("| " + headers.joined(separator: " | ") + " |")
        lines.append("| " + headers.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows {
            // Pad short rows to header count
            var cells = row
            while cells.count < headers.count { cells.append("") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Three.js Code Dropdown

struct VisualizationGeneratingView: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            // Rotating cube icon
            Image(systemName: "cube.fill")
                .font(.system(size: 13))
                .foregroundColor(.green.opacity(0.7))
                .rotationEffect(.degrees(phase * 360))
                .animation(.linear(duration: 2.0).repeatForever(autoreverses: false), value: phase)

            Text("Building visualization...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            // Shimmering dots
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.green.opacity(0.6))
                        .frame(width: 4, height: 4)
                        .opacity(phase.truncatingRemainder(dividingBy: 1) > Double(i) * 0.33 ? 1 : 0.25)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.2), lineWidth: 1))
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

struct ThreeJSCodeDropdown: View {
    let code: String?
    @State private var isExpanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — always visible
            HStack(spacing: 6) {
                // Toggle expand button
                Button(action: { withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green.opacity(0.85))
                        Text("Three.js Visualization")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.green.opacity(0.85))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 10)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)

                Spacer()

                // Reopen window button
                if let code {
                    Button(action: {
                        VisualizationWindowManager.shared.openVisualization(code: code)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10))
                            Text("Open")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.green.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }

            // Expandable code block
            if isExpanded, let code {
                Divider()
                    .padding(.horizontal, 6)

                ZStack(alignment: .topTrailing) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(code)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 340)

                    // Copy button
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }) {
                        Text(copied ? "Copied!" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(copied ? .green : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.25), lineWidth: 1))
        .frame(maxWidth: 520)
    }
}

// MARK: - Translation Panel

struct TranslationPanel: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 9))
                Text("Translation")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.secondary.opacity(0.55))

            Text(styledText)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private var styledText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: text, options: options) {
            return attr
        }
        return AttributedString(text)
    }
}

// MARK: - LaTeX Rendering

struct LaTeXBlockView: View {
    let latex: String
    @State private var height: CGFloat = 50

    var body: some View {
        LaTeXWebView(latex: latex, dynamicHeight: $height)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct LaTeXWebView: NSViewRepresentable {
    let latex: String
    @Binding var dynamicHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "sizeNotify")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 50), configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let escaped = latex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <style>
            body {
                margin: 0; padding: 8px 4px;
                background: transparent;
                color: #E5E5EA;
                font-size: 15px;
            }
            .katex { font-size: 1.15em; }
        </style>
        </head>
        <body>
        <div id="math"></div>
        <script>
            try {
                katex.render("\(escaped)", document.getElementById("math"), {
                    displayMode: true,
                    throwOnError: false,
                    output: "html"
                });
            } catch(e) {
                document.getElementById("math").innerText = "\(escaped)";
            }
            setTimeout(function() {
                window.webkit.messageHandlers.sizeNotify.postMessage(
                    document.body.scrollHeight
                );
            }, 150);
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: LaTeXWebView

        init(parent: LaTeXWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    self.parent.dynamicHeight = max(height + 4, 30)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                if let height = result as? CGFloat {
                    DispatchQueue.main.async {
                        self.parent.dynamicHeight = max(height + 4, 30)
                    }
                }
            }
        }
    }
}

// MARK: - Capabilities (Skills) Sheet

/// "What can Pendragon do?" — discoverability for every built-in skill.
/// Rows with an example prompt are clickable: the prompt is inserted into the
/// input field so the user can try the skill immediately.
struct CapabilitiesView: View {
    @Binding var isPresented: Bool
    var insertExample: (String) -> Void

    private struct Skill: Identifiable {
        let id = UUID()
        let icon: String
        let color: Color
        let name: String
        let detail: String
        var example: String? = nil
    }

    private struct SkillGroup: Identifiable {
        let id = UUID()
        let title: String
        let skills: [Skill]
    }

    private var groups: [SkillGroup] {
        [
            SkillGroup(title: "Ask anything", skills: [
                Skill(icon: "brain.head.profile", color: .purple,
                      name: "Reasoning & thinking",
                      detail: "Gemma 4 reasons through complex questions before answering. Toggle with the Thinking button in the toolbar.",
                      example: "If I save 5,000 kr a month at 6% annual return, how long until I have a million?"),
                Skill(icon: "character.bubble", color: .teal,
                      name: "Translation mode",
                      detail: "Toggle Translate in the toolbar — every message you send is translated to English with a word-by-word gloss."),
            ]),
            SkillGroup(title: "See, hear, read", skills: [
                Skill(icon: "photo", color: .orange,
                      name: "Understand images",
                      detail: "Paste (⌘V) or attach up to 4 photos with the paperclip and ask about them.",
                      example: "What's in this photo?"),
                Skill(icon: "mic", color: .red,
                      name: "Voice messages",
                      detail: "Hold the microphone button to record — Pendragon listens to your audio directly."),
                Skill(icon: "doc.text", color: .indigo,
                      name: "Read PDFs",
                      detail: "Attach a PDF and ask questions about its content.",
                      example: "Summarize the attached PDF in five bullet points."),
            ]),
            SkillGroup(title: "Connected to your world", skills: [
                Skill(icon: "globe", color: .blue,
                      name: "Web search",
                      detail: "Toggle Search in the toolbar for answers grounded in fresh results, with sources.",
                      example: "What is today's news?"),
                Skill(icon: "link", color: .cyan,
                      name: "Read web pages",
                      detail: "Paste any URL and Pendragon fetches and reads the page before answering.",
                      example: "Summarize this page: https://en.wikipedia.org/wiki/Uther_Pendragon"),
                Skill(icon: "calendar", color: .red,
                      name: "Apple Calendar",
                      detail: "Create events or ask what's coming up.",
                      example: "Add lunch with Anna on Friday at noon to my calendar"),
                Skill(icon: "checklist", color: .orange,
                      name: "Apple Reminders",
                      detail: "Add reminders to any list, or ask what's on them.",
                      example: "Remind me to water the plants tomorrow at 9"),
            ]),
            SkillGroup(title: "Create & compute", skills: [
                Skill(icon: "function", color: .green,
                      name: "Accurate calculations",
                      detail: "Finance, statistics, physics — Pendragon writes and runs Python for exact numbers.",
                      example: "What's the monthly payment on a 4M kr loan at 5.4% over 25 years?"),
                Skill(icon: "cube.transparent", color: .pink,
                      name: "3D visualizations",
                      detail: "Interactive Three.js scenes open in their own window.",
                      example: "Show me an interactive 3D visualization of the solar system"),
                Skill(icon: "speaker.wave.2", color: .mint,
                      name: "Listen",
                      detail: "Every reply has a Listen button — Pendragon reads it aloud with on-device TTS."),
                Skill(icon: "hare", color: .yellow,
                      name: "Boost",
                      detail: "Toggle Boost in the toolbar for maximum generation speed."),
            ]),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Pendragon Skills", systemImage: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Everything below runs entirely on your Mac. Click an example to try it.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.8)
                            ForEach(group.skills) { skill in
                                skillRow(skill)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func skillRow(_ skill: Skill) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: skill.icon)
                .font(.system(size: 14))
                .foregroundColor(skill.color)
                .frame(width: 30, height: 30)
                .background(Circle().fill(skill.color.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(skill.detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let example = skill.example {
                    Button(action: {
                        insertExample(example)
                        isPresented = false
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9))
                            Text(example)
                                .font(.system(size: 11))
                                .italic()
                                .lineLimit(1)
                        }
                        .foregroundColor(skill.color.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(skill.color.opacity(0.08))
                        )
                    }
                    .buttonStyle(.borderless)
                    .help("Insert this example into the message field")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface.opacity(0.5))
        )
    }
}
