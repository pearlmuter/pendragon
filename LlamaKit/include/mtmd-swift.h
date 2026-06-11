#ifndef MTMD_SWIFT_H
#define MTMD_SWIFT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// Forward declarations matching mtmd.h C API
// These are opaque types for Swift
typedef struct mtmd_context      mtmd_context;
typedef struct mtmd_bitmap       mtmd_bitmap;
typedef struct mtmd_image_tokens mtmd_image_tokens;
typedef struct mtmd_input_chunk  mtmd_input_chunk;
typedef struct mtmd_input_chunks mtmd_input_chunks;

struct mtmd_input_text {
    const char * text;
    bool add_special;
    bool parse_special;
};

typedef struct mtmd_input_text mtmd_input_text;

enum mtmd_input_chunk_type {
    MTMD_INPUT_CHUNK_TYPE_TEXT,
    MTMD_INPUT_CHUNK_TYPE_IMAGE,
    MTMD_INPUT_CHUNK_TYPE_AUDIO,
};

struct mtmd_context_params {
    bool use_gpu;
    bool print_timings;
    int n_threads;
    const char * image_marker;
    const char * media_marker;
    int flash_attn_type;
    bool warmup;
    int image_min_tokens;
    int image_max_tokens;
    void * cb_eval;
    void * cb_eval_user_data;
};

// Core API
extern const char * mtmd_default_marker(void);
extern struct mtmd_context_params mtmd_context_params_default(void);
extern mtmd_context * mtmd_init_from_file(const char * mmproj_fname,
                                          const void * text_model,
                                          const struct mtmd_context_params ctx_params);
extern void mtmd_free(mtmd_context * ctx);
extern bool mtmd_support_vision(const mtmd_context * ctx);
extern bool mtmd_support_audio(const mtmd_context * ctx);

// Bitmap (image)
extern mtmd_bitmap * mtmd_bitmap_init(uint32_t nx, uint32_t ny, const unsigned char * data);
// Bitmap (audio) - data is PCM F32, n_samples is number of float samples
extern mtmd_bitmap * mtmd_bitmap_init_from_audio(size_t n_samples, const float * data);
extern bool mtmd_bitmap_is_audio(const mtmd_bitmap * bitmap);
extern void mtmd_bitmap_free(mtmd_bitmap * bitmap);

// Audio sample rate
extern int mtmd_get_audio_sample_rate(const mtmd_context * ctx);

// Input chunks
extern mtmd_input_chunks * mtmd_input_chunks_init(void);
extern size_t mtmd_input_chunks_size(const mtmd_input_chunks * chunks);
extern const mtmd_input_chunk * mtmd_input_chunks_get(const mtmd_input_chunks * chunks, size_t idx);
extern void mtmd_input_chunks_free(mtmd_input_chunks * chunks);

// Tokenize
extern int32_t mtmd_tokenize(mtmd_context * ctx,
                             mtmd_input_chunks * output,
                             const mtmd_input_text * text,
                             const mtmd_bitmap ** bitmaps,
                             size_t n_bitmaps);

// Helper
extern mtmd_bitmap * mtmd_helper_bitmap_init_from_file(mtmd_context * ctx, const char * fname, bool placeholder);
extern mtmd_bitmap * mtmd_helper_bitmap_init_from_buf(mtmd_context * ctx, const unsigned char * buf, size_t len, bool placeholder);
extern size_t mtmd_helper_get_n_tokens(const mtmd_input_chunks * chunks);

extern int32_t mtmd_helper_eval_chunks(mtmd_context * ctx,
                                       void * lctx,
                                       const mtmd_input_chunks * chunks,
                                       int32_t n_past,
                                       int32_t seq_id,
                                       int32_t n_batch,
                                       bool logits_last,
                                       int32_t * new_n_past);

#endif
