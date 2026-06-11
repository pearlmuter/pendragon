/**
 * KokoroTTS.cpp
 * Native Kokoro TTS implementation for Pendragon.
 *
 * Pipeline:
 *   text → espeak-ng (IPA phonemes) → vocab lookup (int64 tokens)
 *        → ONNX Runtime (kokoro-v1.0.onnx) → float32 PCM @ 24kHz
 */

#include "KokoroTTS.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

// ONNX Runtime C API
#include "onnxruntime_c_api.h"

// ─── IPA vocabulary (114 entries, from kokoro config.json) ───────────────────
// Maps UTF-8 IPA character → token id
static const std::pair<const char*, int> kVocabData[] = {
    {";", 1}, {":", 2}, {",", 3}, {".", 4}, {"!", 5}, {"?", 6},
    {"\xe2\x80\x94", 9},   // —
    {"\xe2\x80\xa6", 10},  // …
    {"\"", 11}, {"(", 12}, {")", 13},
    {"\xe2\x80\x9c", 14},  // "
    {"\xe2\x80\x9d", 15},  // "
    {" ", 16},
    {"\xcc\x83", 17},       // ̃
    {"\xca\xa3", 18},       // ʣ
    {"\xca\xa5", 19},       // ʥ
    {"\xca\xa6", 20},       // ʦ
    {"\xca\xa8", 21},       // ʨ
    {"\xe1\xb5\x9d", 22},   // ᵝ
    {"\xea\xad\xa7", 23},   // ꭧ
    {"A", 24}, {"I", 25}, {"O", 31}, {"Q", 33}, {"S", 35},
    {"T", 36}, {"W", 39}, {"Y", 41},
    {"\xe1\xb5\x8a", 42},   // ᵊ
    {"a", 43}, {"b", 44}, {"c", 45}, {"d", 46}, {"e", 47},
    {"f", 48}, {"h", 50}, {"i", 51}, {"j", 52}, {"k", 53},
    {"l", 54}, {"m", 55}, {"n", 56}, {"o", 57}, {"p", 58},
    {"q", 59}, {"r", 60}, {"s", 61}, {"t", 62}, {"u", 63},
    {"v", 64}, {"w", 65}, {"x", 66}, {"y", 67}, {"z", 68},
    {"\xc9\x91", 69},   // ɑ
    {"\xc9\x90", 70},   // ɐ
    {"\xc9\x92", 71},   // ɒ
    {"\xc3\xa6", 72},   // æ
    {"\xce\xb2", 75},   // β
    {"\xc9\x94", 76},   // ɔ
    {"\xc9\x95", 77},   // ɕ
    {"\xc3\xa7", 78},   // ç
    {"\xc9\x96", 80},   // ɖ
    {"\xc3\xb0", 81},   // ð
    {"\xca\xa4", 82},   // ʤ
    {"\xc9\x99", 83},   // ə
    {"\xc9\x9a", 85},   // ɚ
    {"\xc9\x9b", 86},   // ɛ
    {"\xc9\x9c", 87},   // ɜ
    {"\xc9\x9f", 90},   // ɟ
    {"\xc9\xa1", 92},   // ɡ
    {"\xc9\xa5", 99},   // ɥ
    {"\xc9\xa8", 101},  // ɨ
    {"\xc9\xaa", 102},  // ɪ
    {"\xca\x9d", 103},  // ʝ
    {"\xc9\xaf", 110},  // ɯ
    {"\xc9\xb0", 111},  // ɰ
    {"\xc5\x8b", 112},  // ŋ
    {"\xc9\xb3", 113},  // ɳ
    {"\xc9\xb2", 114},  // ɲ
    {"\xc9\xb4", 115},  // ɴ
    {"\xc3\xb8", 116},  // ø
    {"\xc9\xb8", 118},  // ɸ
    {"\xce\xb8", 119},  // θ
    {"\xc5\x93", 120},  // œ
    {"\xc9\xb9", 123},  // ɹ
    {"\xc9\xbe", 125},  // ɾ
    {"\xc9\xbb", 126},  // ɻ
    {"\xca\x81", 128},  // ʁ
    {"\xc9\xbd", 129},  // ɽ
    {"\xca\x82", 130},  // ʂ
    {"\xca\x83", 131},  // ʃ
    {"\xca\x88", 132},  // ʈ
    {"\xca\xa7", 133},  // ʧ
    {"\xca\x8a", 135},  // ʊ
    {"\xca\x8b", 136},  // ʋ
    {"\xca\x8c", 138},  // ʌ
    {"\xc9\xa3", 139},  // ɣ
    {"\xc9\xa4", 140},  // ɤ
    {"\xcf\x87", 142},  // χ
    {"\xca\x8e", 143},  // ʎ
    {"\xca\x92", 147},  // ʒ
    {"\xca\x94", 148},  // ʔ
    {"\xcb\x88", 156},  // ˈ
    {"\xcb\x8c", 157},  // ˌ
    {"\xcb\x90", 158},  // ː
    {"\xcb\xb0", 162},  // ʰ
    {"\xcb\xb2", 164},  // ʲ
    {"\xe2\x86\x93", 169},  // ↓
    {"\xe2\x86\x92", 171},  // →
    {"\xe2\x86\x97", 172},  // ↗
    {"\xe2\x86\x98", 173},  // ↘
    {"\xe1\xb5\xbb", 177},  // ᵻ
};

static constexpr int MAX_PHONEMES = 510;

// ─── espeak-ng function pointer types ────────────────────────────────────────
typedef void   (*fn_espeak_ng_InitializePath)(const char*);
typedef int    (*fn_espeak_Initialize)(int, int, const char*, int);
typedef int    (*fn_espeak_SetVoiceByName)(const char*);
typedef const char* (*fn_espeak_TextToPhonemes)(const void**, int, int);
typedef int    (*fn_espeak_ng_Terminate)(void);

// ─── KokoroTTS implementation ─────────────────────────────────────────────────
struct KokoroImpl {
    // espeak-ng
    void* espeak_lib_handle = nullptr;
    fn_espeak_ng_InitializePath  espeak_ng_InitializePath  = nullptr;
    fn_espeak_Initialize         espeak_Initialize         = nullptr;
    fn_espeak_SetVoiceByName     espeak_SetVoiceByName     = nullptr;
    fn_espeak_TextToPhonemes     espeak_TextToPhonemes     = nullptr;
    fn_espeak_ng_Terminate       espeak_ng_Terminate       = nullptr;
    bool espeak_ready = false;

    // ONNX Runtime
    const OrtApi* ort = nullptr;
    OrtEnv* env = nullptr;
    OrtSession* session = nullptr;
    OrtSessionOptions* session_options = nullptr;
    OrtMemoryInfo* memory_info = nullptr;

    // Vocabulary: UTF-8 string → token id
    std::unordered_map<std::string, int> vocab;

    // Voices: name → [510][256] float32
    struct Voice {
        std::string name;
        std::vector<float> data;  // shape [510 * 256]
    };
    std::vector<Voice> voices;
    std::unordered_map<std::string, size_t> voice_index;

    // Error string
    char error_buf[512] = {};
};

static thread_local char g_error_buf[512] = {};

static void set_error(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_error_buf, sizeof(g_error_buf), fmt, ap);
    va_end(ap);
}

// ─── UTF-8 helpers ────────────────────────────────────────────────────────────
// Returns the byte length of the next UTF-8 codepoint starting at s[i].
static int utf8_char_len(const unsigned char* s) {
    unsigned char c = s[0];
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if ((c & 0xF8) == 0xF0) return 4;
    return 1;  // fallback
}

// ─── Vocabulary builder ────────────────────────────────────────────────────────
static void build_vocab(std::unordered_map<std::string, int>& vocab) {
    const int n = (int)(sizeof(kVocabData) / sizeof(kVocabData[0]));
    for (int i = 0; i < n; ++i)
        vocab[kVocabData[i].first] = kVocabData[i].second;
}

// ─── Voices loader ─────────────────────────────────────────────────────────────
// Binary format (little-endian):
//   uint32  num_voices
//   For each voice:
//     uint32  name_len
//     char    name[name_len]
//     uint32  rows (= 510)
//     uint32  cols (= 256)
//     float32 data[rows * cols]
static bool load_voices(const char* path,
                        std::vector<KokoroImpl::Voice>& voices,
                        std::unordered_map<std::string, size_t>& index) {
    FILE* f = fopen(path, "rb");
    if (!f) { set_error("Cannot open voices file: %s", path); return false; }

    auto read_u32 = [&](uint32_t& v) { return fread(&v, 4, 1, f) == 1; };

    uint32_t num = 0;
    if (!read_u32(num)) { fclose(f); set_error("Cannot read voices count"); return false; }

    voices.resize(num);
    for (uint32_t i = 0; i < num; ++i) {
        uint32_t name_len = 0;
        if (!read_u32(name_len)) { fclose(f); set_error("Cannot read voice name len"); return false; }
        voices[i].name.resize(name_len);
        if (fread(voices[i].name.data(), 1, name_len, f) != name_len) {
            fclose(f); set_error("Cannot read voice name"); return false;
        }

        uint32_t rows = 0, cols = 0;
        if (!read_u32(rows) || !read_u32(cols)) {
            fclose(f); set_error("Cannot read voice shape"); return false;
        }

        voices[i].data.resize(rows * cols);
        if (fread(voices[i].data.data(), sizeof(float), rows * cols, f) != rows * cols) {
            fclose(f); set_error("Cannot read voice data for %s", voices[i].name.c_str()); return false;
        }
        index[voices[i].name] = i;
    }
    fclose(f);
    return true;
}

// ─── E2M phoneme normalization ────────────────────────────────────────────────
// Convert raw espeak IPA output to Kokoro vocab tokens.
// espeak outputs diphthongs as two-character sequences (e.g. "eɪ");
// Kokoro expects them as single dedicated tokens (e.g. "A").
// Without this, the model receives completely wrong phoneme sequences.
static std::string apply_e2m(const std::string& raw, bool is_bre) {
    struct Repl { const char* from; const char* to; };

    // Common English: applied first, longest patterns first to avoid
    // partial-match issues (e.g. "eɪ" must be replaced before bare "e").
    static const Repl common[] = {
        // Affricates: two-char espeak → single ligature Kokoro token
        {"d\xca\x92",           "\xca\xa4"},        // dʒ → ʤ  (U+02A4)
        {"t\xca\x83",           "\xca\xa7"},        // tʃ → ʧ  (U+02A7)
        // Diphthongs: two-char espeak → single uppercase Kokoro token
        {"a\xc9\xaa",           "I"},               // aɪ → I
        {"a\xca\x8a",           "W"},               // aʊ → W
        {"e\xc9\xaa",           "A"},               // eɪ → A  (must precede bare e)
        {"\xc9\x94\xc9\xaa",    "Y"},               // ɔɪ → Y
        // Rhotic schwa expansion (ɚ → ə + ɹ)
        {"\xc9\x9a",            "\xc9\x99\xc9\xb9"},// ɚ → əɹ
        // Single-char substitutions
        {"\xc9\xac",            "l"},               // ɬ → l
        {"\xc9\x90",            "\xc9\x99"},        // ɐ → ə
        {"\xc3\xa7",            "k"},               // ç → k
        {"x",                   "k"},               // x → k
        {"r",                   "\xc9\xb9"},        // r → ɹ  (bare ASCII r)
        {"e",                   "A"},               // e → A  (bare e after eɪ handled)
        {nullptr, nullptr}
    };
    // American English specific
    static const Repl ame[] = {
        {"o\xca\x8a",           "O"},               // oʊ → O
        {"\xc9\xbe",            "T"},               // ɾ → T  (flap)
        {"\xca\x94",            "t"},               // ʔ → t  (glottal stop)
        {"\xc9\x9d",            "\xc9\x9c\xc9\xb9"},// ɝ → ɜɹ (stressed rhotic: bird/word/heard)
        {nullptr, nullptr}
    };
    // British English specific
    static const Repl bre[] = {
        {"\xc9\x99\xca\x8a",    "Q"},               // əʊ → Q
        {"e\xc9\x99",           "\xc9\x9b\xc2\xb7"},// eə → ɛ·  (SQUARE vowel approx)
        {nullptr, nullptr}
    };

    // Apply a replacement list to a string (find-and-replace each rule in order)
    auto apply = [](std::string s, const Repl* rs) -> std::string {
        for (int i = 0; rs[i].from; ++i) {
            std::string f(rs[i].from), t(rs[i].to);
            size_t pos = 0;
            while ((pos = s.find(f, pos)) != std::string::npos) {
                s.replace(pos, f.size(), t);
                pos += t.size();
            }
        }
        return s;
    };

    std::string result = apply(raw, common);
    result = apply(result, is_bre ? bre : ame);
    return result;
}

// ─── Per-chunk silence trim ────────────────────────────────────────────────────
// Trim leading and trailing near-silence from an audio chunk.
// Uses RMS energy in overlapping frames; drops frames below top_db dB from peak.
// Matches the librosa.effects.trim() call in the reference Python implementation.
static std::vector<float> trim_silence(std::vector<float> audio, float top_db = 60.f) {
    if (audio.empty()) return audio;

    const int frame_len = 2048;
    const int hop_len   = 512;
    const int n         = (int)audio.size();

    // Compute per-frame RMS
    std::vector<float> rms;
    for (int i = 0; i < n; i += hop_len) {
        int end = std::min(i + frame_len, n);
        float sq = 0.f;
        for (int j = i; j < end; ++j) sq += audio[j] * audio[j];
        rms.push_back(std::sqrt(sq / float(end - i)));
    }
    if (rms.empty()) return {};

    float peak = *std::max_element(rms.begin(), rms.end());
    if (peak == 0.f) return {};

    // Linear threshold equivalent to -top_db dB below peak
    float thresh = peak * std::pow(10.f, -top_db / 20.f);

    int first = -1, last = -1;
    for (int i = 0; i < (int)rms.size(); ++i) {
        if (rms[i] >= thresh) {
            if (first < 0) first = i;
            last = i;
        }
    }
    if (first < 0) return {};

    // Convert frames → samples; add one-hop margin at start to preserve attack
    int s0 = std::max(0, first * hop_len - hop_len);
    int s1 = std::min(n, (last + 1) * hop_len + frame_len);

    return std::vector<float>(audio.begin() + s0, audio.begin() + s1);
}

// ─── espeak-ng phonemizer ──────────────────────────────────────────────────────
// Phonemize one chunk of plain text (no punctuation) with espeak.
// Applies E2M normalization then filters to vocab characters.
static std::string phonemize_chunk(KokoroImpl* impl,
                                   const std::string& text,
                                   const std::unordered_map<std::string, int>& vocab,
                                   bool is_bre) {
    if (text.empty()) return "";

    // phonemes_mode: IPA output only — NO phoneme separator.
    // Using a separator character (e.g. '_') inserts it between phonemes
    // *within* each word, which we'd then convert to space token 16, putting
    // word-boundary tokens inside words and breaking syllable grouping/stress.
    const int phonemes_mode = 0x02;  // espeakPHONEMES_IPA
    const int text_mode = 1;         // UTF-8

    const char* cstr = text.c_str();
    const void* ptr = (const void*)cstr;

    // Collect all espeak chunks and join with spaces
    std::vector<std::string> chunks;
    while (ptr != nullptr) {
        const char* ph = impl->espeak_TextToPhonemes(&ptr, text_mode, phonemes_mode);
        if (ph && *ph) chunks.push_back(ph);
    }
    if (chunks.empty()) return "";

    std::string raw;
    for (size_t k = 0; k < chunks.size(); ++k) {
        if (k > 0) raw += " ";
        raw += chunks[k];
    }

    // Apply E2M normalization (diphthong/affricate substitutions)
    std::string normalized = apply_e2m(raw, is_bre);

    // Filter: keep only vocab characters (space passes through as token 16)
    std::string filtered;
    const unsigned char* s = (const unsigned char*)normalized.c_str();
    size_t len = normalized.size();
    size_t i = 0;
    while (i < len) {
        int clen = utf8_char_len(s + i);
        std::string ch(normalized.c_str() + i, clen);
        if (vocab.count(ch)) filtered += ch;
        i += clen;
    }
    return filtered;
}

// Full phonemize: split input at punctuation, phonemize text segments,
// re-insert punctuation tokens so the model gets natural cadence.
static std::string phonemize(KokoroImpl* impl,
                              const std::string& text,
                              const std::unordered_map<std::string, int>& vocab,
                              bool is_bre) {
    // Punctuation characters that live in the Kokoro vocab
    static const std::string PUNCT = ";:,.!?—…\"()""";

    std::string result;
    std::string word_buf;  // accumulates non-punctuation text

    auto flush_word_buf = [&]() {
        if (word_buf.empty()) return;
        // Trim whitespace
        size_t s = word_buf.find_first_not_of(" \t\r\n");
        size_t e = word_buf.find_last_not_of(" \t\r\n");
        if (s == std::string::npos) { word_buf.clear(); return; }
        std::string trimmed = word_buf.substr(s, e - s + 1);
        word_buf.clear();
        if (trimmed.empty()) return;
        std::string ph = phonemize_chunk(impl, trimmed, vocab, is_bre);
        if (!ph.empty()) {
            if (!result.empty() && result.back() != ' ') result += ' ';
            result += ph;
        }
    };

    // Walk the UTF-8 text character by character
    const unsigned char* us = (const unsigned char*)text.c_str();
    size_t len = text.size();
    size_t i = 0;
    while (i < len) {
        int clen = utf8_char_len(us + i);
        std::string ch(text.c_str() + i, clen);
        i += clen;

        // Is this character a punctuation vocab token?
        bool is_punct = false;
        if (vocab.count(ch)) {
            // ASCII punctuation from PUNCT list
            if (ch.size() == 1 && PUNCT.find(ch[0]) != std::string::npos) {
                is_punct = true;
            }
            // Multi-byte punctuation: em-dash, ellipsis, curly quotes
            else if (ch.size() > 1) {
                is_punct = true;
            }
        }
        // Whitespace / newline — flush and skip
        if (ch.size() == 1 && (ch[0] == '\n' || ch[0] == '\r')) {
            flush_word_buf();
            // Newline acts like a brief pause — add a space
            if (!result.empty() && result.back() != ' ') result += ' ';
            continue;
        }

        if (is_punct) {
            flush_word_buf();
            if (!result.empty() && result.back() != ' ') result += ' ';
            result += ch;
            result += ' ';
        } else {
            word_buf += ch;
        }
    }
    flush_word_buf();

    // Collapse multiple spaces and trim
    std::string out;
    bool last_space = true;  // true to trim leading space
    for (char c : result) {
        if (c == ' ') {
            if (!last_space) { out += c; last_space = true; }
        } else {
            out += c; last_space = false;
        }
    }
    // Trim trailing space
    while (!out.empty() && out.back() == ' ') out.pop_back();
    return out;
}

// ─── Tokenizer ─────────────────────────────────────────────────────────────────
static std::vector<int64_t> tokenize(const std::string& phonemes,
                                     const std::unordered_map<std::string, int>& vocab) {
    std::vector<int64_t> tokens;
    const unsigned char* s = (const unsigned char*)phonemes.c_str();
    size_t len = phonemes.size();
    size_t i = 0;
    while (i < len) {
        int clen = utf8_char_len(s + i);
        std::string ch(phonemes.c_str() + i, clen);
        auto it = vocab.find(ch);
        if (it != vocab.end()) {
            tokens.push_back(it->second);
        }
        i += clen;
    }
    return tokens;
}

// ─── Phoneme splitter ─────────────────────────────────────────────────────────
// Split phonemes into sentence-sized chunks for best ONNX quality.
// Always splits at sentence-ending punctuation (. ! ?); also splits at
// MAX_PHONEMES as a hard safety cap.
static std::vector<std::string> split_phonemes(const std::string& phonemes) {
    std::vector<std::string> batches;
    if (phonemes.empty()) return batches;

    const unsigned char* s = (const unsigned char*)phonemes.c_str();
    size_t len = phonemes.size();
    size_t start = 0;
    int count = 0;
    size_t last_soft = std::string::npos;   // last space or comma — fallback split
    size_t last_soft_byte = 0;

    auto push_chunk = [&](size_t end_byte) {
        // Strip trailing space
        while (end_byte > start && phonemes[end_byte - 1] == ' ') --end_byte;
        if (end_byte > start) batches.push_back(phonemes.substr(start, end_byte - start));
        start = end_byte;
        // Skip leading space in next chunk
        while (start < len && phonemes[start] == ' ') ++start;
        count = 0;
        last_soft = std::string::npos;
        last_soft_byte = 0;
    };

    for (size_t i = 0; i < len; ) {
        int clen = utf8_char_len(s + i);
        char ch = (char)s[i];

        // Track soft break points (space / comma)
        if (ch == ' ' || ch == ',') {
            last_soft = count;
            last_soft_byte = i + clen;
        }

        count++;
        i += clen;

        // Hard sentence boundary — split AFTER the punctuation char
        // Require at least a few tokens before splitting to avoid tiny fragments
        if ((ch == '.' || ch == '!' || ch == '?') && count > 5) {
            // Skip any trailing space before the next chunk
            size_t end_byte = i;
            push_chunk(end_byte);
            i = start;
            continue;
        }

        // Safety cap: split at last soft break (or hard if none)
        if (count >= MAX_PHONEMES - 2) {
            size_t end_byte = (last_soft != std::string::npos) ? last_soft_byte : i;
            push_chunk(end_byte);
            i = start;
        }
    }
    if (start < len) {
        std::string tail = phonemes.substr(start);
        while (!tail.empty() && tail.back() == ' ') tail.pop_back();
        if (!tail.empty()) batches.push_back(tail);
    }
    return batches;
}

// ─── ONNX inference for one chunk ─────────────────────────────────────────────
static bool run_inference(KokoroImpl* impl,
                          const std::vector<int64_t>& raw_tokens,
                          const float* style,           // [256]
                          float speed,
                          std::vector<float>& audio_out) {
    const OrtApi* ort = impl->ort;

    // tokens: [0, *raw_tokens, 0]
    std::vector<int64_t> tokens;
    tokens.reserve(raw_tokens.size() + 2);
    tokens.push_back(0);
    tokens.insert(tokens.end(), raw_tokens.begin(), raw_tokens.end());
    tokens.push_back(0);

    int64_t tokens_len = (int64_t)tokens.size();
    int64_t style_len  = 256;

    // Build input tensors
    OrtValue* t_tokens  = nullptr;
    OrtValue* t_style   = nullptr;
    OrtValue* t_speed   = nullptr;

    int64_t tokens_shape[2] = {1, tokens_len};
    int64_t style_shape[2]  = {1, 256};
    int64_t speed_shape[1]  = {1};

    OrtStatus* status = nullptr;

    status = ort->CreateTensorWithDataAsOrtValue(
        impl->memory_info,
        (void*)tokens.data(), tokens.size() * sizeof(int64_t),
        tokens_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t_tokens);
    if (status) { set_error("ORT: %s", ort->GetErrorMessage(status)); ort->ReleaseStatus(status); return false; }

    status = ort->CreateTensorWithDataAsOrtValue(
        impl->memory_info,
        (void*)style, 256 * sizeof(float),
        style_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &t_style);
    if (status) { ort->ReleaseValue(t_tokens); set_error("ORT: %s", ort->GetErrorMessage(status)); ort->ReleaseStatus(status); return false; }

    float speed_val = speed;
    status = ort->CreateTensorWithDataAsOrtValue(
        impl->memory_info,
        &speed_val, sizeof(float),
        speed_shape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &t_speed);
    if (status) { ort->ReleaseValue(t_tokens); ort->ReleaseValue(t_style); set_error("ORT: %s", ort->GetErrorMessage(status)); ort->ReleaseStatus(status); return false; }

    const char* input_names[]  = {"tokens", "style", "speed"};
    const char* output_names[] = {"audio"};
    OrtValue* inputs[]  = {t_tokens, t_style, t_speed};
    OrtValue* outputs[] = {nullptr};

    status = ort->Run(impl->session, nullptr,
                      input_names, (const OrtValue* const*)inputs, 3,
                      output_names, 1, outputs);
    ort->ReleaseValue(t_tokens);
    ort->ReleaseValue(t_style);
    ort->ReleaseValue(t_speed);

    if (status) {
        set_error("ORT Run: %s", ort->GetErrorMessage(status));
        ort->ReleaseStatus(status);
        return false;
    }

    // Extract output
    float* out_data = nullptr;
    status = ort->GetTensorMutableData(outputs[0], (void**)&out_data);
    if (status) {
        ort->ReleaseValue(outputs[0]);
        set_error("ORT GetData: %s", ort->GetErrorMessage(status));
        ort->ReleaseStatus(status);
        return false;
    }

    OrtTensorTypeAndShapeInfo* shape_info = nullptr;
    status = ort->GetTensorTypeAndShape(outputs[0], &shape_info);
    if (status) {
        ort->ReleaseValue(outputs[0]);
        set_error("ORT GetShape: %s", ort->GetErrorMessage(status));
        ort->ReleaseStatus(status);
        return false;
    }

    size_t elem_count = 0;
    ort->GetTensorShapeElementCount(shape_info, &elem_count);
    ort->ReleaseTensorTypeAndShapeInfo(shape_info);

    audio_out.insert(audio_out.end(), out_data, out_data + elem_count);
    ort->ReleaseValue(outputs[0]);
    return true;
}

// ─── Public C API ─────────────────────────────────────────────────────────────

extern "C" {

const char* kokoro_last_error(void) {
    return g_error_buf;
}

KokoroHandle kokoro_create(const char* model_path,
                           const char* voices_path,
                           const char* espeak_lib,
                           const char* espeak_data) {
    auto* impl = new KokoroImpl();

    // 1. Load espeak-ng
    impl->espeak_lib_handle = dlopen(espeak_lib, RTLD_LAZY | RTLD_LOCAL);
    if (!impl->espeak_lib_handle) {
        set_error("dlopen espeak-ng failed: %s", dlerror());
        delete impl; return nullptr;
    }

#define LOAD_SYM(name) \
    impl->name = (fn_##name)dlsym(impl->espeak_lib_handle, #name); \
    if (!impl->name) { set_error("dlsym " #name " failed"); delete impl; return nullptr; }

    LOAD_SYM(espeak_ng_InitializePath)
    LOAD_SYM(espeak_Initialize)
    LOAD_SYM(espeak_SetVoiceByName)
    LOAD_SYM(espeak_TextToPhonemes)
    LOAD_SYM(espeak_ng_Terminate)
#undef LOAD_SYM

    // Set data path via env var (works even when espeak_Initialize passes NULL for path)
    setenv("ESPEAK_DATA_PATH", espeak_data, 1);
    impl->espeak_ng_InitializePath(espeak_data);
    int sr = impl->espeak_Initialize(0x02 /*AUDIO_OUTPUT_SYNCHRONOUS*/, 0, nullptr, 0);
    if (sr <= 0) {
        set_error("espeak_Initialize failed (returned %d)", sr);
        delete impl; return nullptr;
    }
    impl->espeak_SetVoiceByName("en-us");  // default; overridden per synthesis call
    impl->espeak_ready = true;

    // 2. Build vocabulary
    build_vocab(impl->vocab);

    // 3. Load voices
    if (!load_voices(voices_path, impl->voices, impl->voice_index)) {
        delete impl; return nullptr;
    }

    // 4. Initialize ONNX Runtime
    impl->ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!impl->ort) {
        set_error("Failed to get ORT API");
        delete impl; return nullptr;
    }

    OrtStatus* status = nullptr;

    status = impl->ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "KokoroTTS", &impl->env);
    if (status) { set_error("ORT CreateEnv: %s", impl->ort->GetErrorMessage(status)); impl->ort->ReleaseStatus(status); delete impl; return nullptr; }

    status = impl->ort->CreateSessionOptions(&impl->session_options);
    if (status) { set_error("ORT CreateSessionOptions: %s", impl->ort->GetErrorMessage(status)); impl->ort->ReleaseStatus(status); delete impl; return nullptr; }

    // Enable CoreML on Apple Silicon for faster inference
    impl->ort->SetSessionGraphOptimizationLevel(impl->session_options, ORT_ENABLE_ALL);

    status = impl->ort->CreateSession(impl->env, model_path, impl->session_options, &impl->session);
    if (status) { set_error("ORT CreateSession: %s", impl->ort->GetErrorMessage(status)); impl->ort->ReleaseStatus(status); delete impl; return nullptr; }

    status = impl->ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &impl->memory_info);
    if (status) { set_error("ORT CreateMemoryInfo: %s", impl->ort->GetErrorMessage(status)); impl->ort->ReleaseStatus(status); delete impl; return nullptr; }

    return (KokoroHandle)impl;
}

void kokoro_destroy(KokoroHandle handle) {
    if (!handle) return;
    auto* impl = (KokoroImpl*)handle;
    if (impl->memory_info)    impl->ort->ReleaseMemoryInfo(impl->memory_info);
    if (impl->session)        impl->ort->ReleaseSession(impl->session);
    if (impl->session_options) impl->ort->ReleaseSessionOptions(impl->session_options);
    if (impl->env)            impl->ort->ReleaseEnv(impl->env);
    if (impl->espeak_ready)   impl->espeak_ng_Terminate();
    if (impl->espeak_lib_handle) dlclose(impl->espeak_lib_handle);
    delete impl;
}

float* kokoro_synthesize(KokoroHandle handle,
                         const char* text,
                         const char* voice_name,
                         float speed,
                         int* out_samples,
                         int* out_sample_rate) {
    if (!handle || !text || !voice_name) { set_error("null argument"); return nullptr; }
    auto* impl = (KokoroImpl*)handle;

    // Clamp speed
    if (speed < 0.5f) speed = 0.5f;
    if (speed > 2.0f) speed = 2.0f;

    // Find voice
    auto vit = impl->voice_index.find(voice_name);
    if (vit == impl->voice_index.end()) {
        set_error("Voice not found: %s", voice_name);
        return nullptr;
    }
    const KokoroImpl::Voice& voice = impl->voices[vit->second];

    // Determine language from voice name prefix:
    //   bf_ / bm_ → British English (en-gb)
    //   af_ / am_ / others → American English (en-us)
    bool is_bre = (strlen(voice_name) >= 2 &&
                   voice_name[0] == 'b' &&
                   (voice_name[1] == 'f' || voice_name[1] == 'm'));
    impl->espeak_SetVoiceByName(is_bre ? "en-gb" : "en-us");

    // Phonemize (with E2M normalization and correct dialect)
    std::string phonemes = phonemize(impl, text, impl->vocab, is_bre);
    if (phonemes.empty()) {
        set_error("Phonemization produced empty output");
        return nullptr;
    }

    // Split into sentence-sized chunks
    auto chunks = split_phonemes(phonemes);
    if (chunks.empty()) { set_error("No phoneme chunks"); return nullptr; }

    std::vector<float> all_audio;

    for (const auto& chunk : chunks) {
        auto tokens = tokenize(chunk, impl->vocab);
        if (tokens.empty()) continue;
        if ((int)tokens.size() >= MAX_PHONEMES - 2) {
            tokens.resize(MAX_PHONEMES - 2);
        }

        // Style vector row = number of content tokens (before padding)
        size_t style_row = tokens.size();
        if (style_row >= 510) style_row = 509;
        const float* style = voice.data.data() + style_row * 256;

        std::vector<float> chunk_audio;
        if (!run_inference(impl, tokens, style, speed, chunk_audio)) {
            return nullptr;
        }

        // Trim leading/trailing silence from each chunk before concatenating.
        // The model tends to generate ~1-2s of near-silence at the start of
        // each chunk; without trimming, sentence boundaries sound clipped.
        auto trimmed = trim_silence(chunk_audio);
        if (!trimmed.empty()) {
            all_audio.insert(all_audio.end(), trimmed.begin(), trimmed.end());
        }
    }

    if (all_audio.empty()) { set_error("Inference produced no audio"); return nullptr; }

    float* result = (float*)malloc(all_audio.size() * sizeof(float));
    if (!result) { set_error("OOM"); return nullptr; }
    memcpy(result, all_audio.data(), all_audio.size() * sizeof(float));
    *out_samples     = (int)all_audio.size();
    *out_sample_rate = 24000;
    return result;
}

void kokoro_free_audio(float* audio) {
    free(audio);
}

char** kokoro_get_voices(KokoroHandle handle, int* out_count) {
    if (!handle) { if (out_count) *out_count = 0; return nullptr; }
    auto* impl = (KokoroImpl*)handle;
    int n = (int)impl->voices.size();
    char** result = (char**)malloc((n + 1) * sizeof(char*));
    if (!result) { if (out_count) *out_count = 0; return nullptr; }
    for (int i = 0; i < n; ++i) {
        result[i] = strdup(impl->voices[i].name.c_str());
    }
    result[n] = nullptr;
    if (out_count) *out_count = n;
    return result;
}

void kokoro_free_voices(char** voices, int count) {
    if (!voices) return;
    for (int i = 0; i < count; ++i) free(voices[i]);
    free(voices);
}

} // extern "C"
