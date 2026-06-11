#pragma once
#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/// Opaque handle to a KokoroTTS instance.
typedef void* KokoroHandle;

/// Create a KokoroTTS instance.
/// - model_path:   absolute path to kokoro-v1.0.onnx
/// - voices_path:  absolute path to voices.bin (pre-converted binary)
/// - espeak_lib:   absolute path to libespeak-ng.dylib
/// - espeak_data:  absolute path to espeak-ng-data directory
/// Returns NULL on failure; call kokoro_last_error() for details.
KokoroHandle kokoro_create(const char* model_path,
                           const char* voices_path,
                           const char* espeak_lib,
                           const char* espeak_data);

/// Destroy a KokoroTTS instance and free all resources.
void kokoro_destroy(KokoroHandle handle);

/// Synthesize text to PCM audio.
/// - text:           UTF-8 input text
/// - voice:          voice name (e.g. "af_heart")
/// - speed:          playback speed [0.5 – 2.0]
/// - out_samples:    filled with the number of float32 samples
/// - out_sample_rate filled with the sample rate (always 24000)
/// Returns a heap-allocated float32 array. Caller must free with kokoro_free_audio().
/// Returns NULL on failure.
float* kokoro_synthesize(KokoroHandle handle,
                         const char* text,
                         const char* voice,
                         float speed,
                         int* out_samples,
                         int* out_sample_rate);

/// Free audio buffer returned by kokoro_synthesize().
void kokoro_free_audio(float* audio);

/// Get the list of available voice names.
/// Returns a NULL-terminated array of C strings. Caller must free with kokoro_free_voices().
char** kokoro_get_voices(KokoroHandle handle, int* out_count);

/// Free voice list returned by kokoro_get_voices().
void kokoro_free_voices(char** voices, int count);

/// Return the last error message (static string, valid until next API call).
const char* kokoro_last_error(void);

#ifdef __cplusplus
} // extern "C"
#endif
