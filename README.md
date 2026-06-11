# Pendragon

A native macOS chat app that runs **Gemma 4 12B** fully locally — no cloud, no API keys, no data leaving your machine.

Built with SwiftUI on top of [llama.cpp](https://github.com/ggml-org/llama.cpp), with a Kokoro TTS engine for voice output and full Apple Silicon GPU acceleration via Metal.

---

## Features

**Multimodal input**
- Attach images (up to 4) — Gemma 4's vision encoder reads them directly
- Attach or record audio (up to 30 s) — Gemma 4's audio tower processes the raw waveform
- Paste or attach PDFs — text is extracted and injected into the prompt

**Text-to-speech**
- Local Kokoro TTS engine with multiple voices and adjustable speed
- Pre-synthesises responses in the background so playback is instant
- Per-message play/pause, skip, and WAV export to Downloads

**Tools the model can use**
- Web search (live results injected before the answer)
- URL fetch (reads any web page on demand)
- Apple Calendar — list events, create events
- Apple Reminders — list reminders, create reminders
- Python execution — runs arbitrary Python 3 scripts for calculations

**3D visualisations**
- Ask for a visual explanation of any concept and the model writes Three.js code that opens in a live interactive window

**Conversation management**
- Sidebar with named threads, pinning, and per-thread history
- Automatic context compaction at 80 % of the context window — older messages are summarised and the KV cache is reset, so conversations never hit a hard stop
- Thinking mode — Gemma reasons silently before answering; only the final response is shown

**Performance controls**
- **Quiet mode** (default): ~10–12 t/s with deliberate throttle — GPU duty-cycles, fanless, matches reading speed
- **Boost mode**: full ~27 t/s for long outputs
- Context size picker: 8K / 32K / 128K / 256K with live RAM estimates

---

## Requirements

- macOS 14 or later
- Apple Silicon (M-series) — the model runs entirely on the Neural Engine / GPU via Metal
- ~10 GB free RAM (model weights ≈ 7.8 GB + KV cache)

**Model files** (not included — obtain separately):

| File | Source |
|------|--------|
| `gemma-4-12B-it-Q4_K_M.gguf` | [lmstudio-community on Hugging Face](https://huggingface.co/lmstudio-community/gemma-4-12B-it-GGUF) |
| `mmproj-gemma-4-12B-it-BF16.gguf` | Same repo — required for vision and audio |

Place both files at:
```
~/.lmstudio/models/lmstudio-community/gemma-4-12B-it-GGUF/
```

---

## Building

```bash
# Clone with submodules (llama.cpp is a submodule)
git clone --recurse-submodules https://github.com/pearlmuter/pendragon.git
cd pendragon

# Build llama.cpp (Metal backend)
cd llama.cpp
cmake -B build -DLLAMA_METAL=ON -DGGML_METAL=ON
cmake --build build --config Release -j$(sysctl -n hw.logicalcpu)
cd ..

# Build and sign the app
xcodebuild -scheme Pendragon -configuration Debug \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-"

codesign --force --deep --sign - build/Build/Products/Debug/Pendragon.app

open build/Build/Products/Debug/Pendragon.app
```

> **Note:** `kokoro/` (the TTS native library, ~870 MB) is not in the repository. TTS will be disabled without it. The rest of the app — chat, vision, audio input, tools — works without kokoro.

---

## Architecture

| Component | Role |
|-----------|------|
| `ChatEngine.swift` | Central coordinator — prompt building, tool dispatch, context compaction, thread management |
| `LlamaEngine.swift` | Swift actor wrapping llama.cpp — model load, KV cache, token generation loop |
| `TTSEngine.swift` | Serial synthesis queue on top of KokoroBridge — disk cache, background pre-synthesis |
| `ChatView.swift` | Main UI — toolbar, message list, input bar, adaptive breakpoints |
| `SettingsView.swift` | Model info, context size picker, TTS voice/speed/model controls |
| `ChatStore.swift` | Thread persistence to Application Support |
| `WebSearchService.swift` | Web search and URL fetch for tool calls |

llama.cpp is vendored as a git submodule at the exact commit the app was built against.

---

## Key llama.cpp parameters

Two parameters are critical for Gemma 4 and must not be changed:

- **`swa_full = false`** — Gemma 4 uses hybrid sliding-window attention: 40 of 48 layers only attend to a 1024-token window. llama.cpp defaults to `swa_full = true`, which allocates a full-size KV cache for every layer and blows memory usage from ~9 GB to ~52 GB at 128K context. Must be false.
- **`n_ubatch = 512`** — The vision/audio encoder emits 256-token image chunks that decode non-causally in one physical batch. A smaller value causes an immediate SIGABRT.
