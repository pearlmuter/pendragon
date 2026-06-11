import Foundation
import llama
import os

/// Thread-safe stop flag that can be set from any thread while the actor is busy
final class AtomicFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var value: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

actor LlamaEngine {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampling: UnsafeMutablePointer<llama_sampler>?
    private var mtmdCtx: OpaquePointer?
    private var batch: llama_batch
    private var temporaryInvalidCChars: [CChar] = []
    private var currentNPast: Int32 = 0
    let stopFlag = AtomicFlag()

    private(set) var isLoaded = false
    private(set) var hasVision = false
    private(set) var hasAudio = false
    var boostMode = false
    private(set) var contextSize: Int32 = 8192
    private(set) var nBatch: Int = 512       // kept in sync with ctxParams.n_batch
    private(set) var lastGenerationTokens: Int = 0
    private(set) var lastGenerationTime: TimeInterval = 0

    func setBoost(_ enabled: Bool) {
        boostMode = enabled
    }

    /// Tear down and recreate the llama context with a new n_ctx value.
    /// The model weights stay in memory — only the KV cache is rebuilt.
    func reloadContext(n_ctx: Int32) throws {
        guard let model else { throw LlamaError.notLoaded }

        // Free existing context and batch
        if let context { llama_free(context) }
        self.context = nil
        llama_batch_free(batch)

        let nBatch  = min(Int(n_ctx) / 8, 2048)
        // n_ubatch must be >= the vision encoder's tokens-per-image (256 for Gemma 4):
        // image embeddings decode non-causally in ONE physical batch, and llama.cpp
        // aborts with "non-causal attention requires n_ubatch >= n_tokens" if it can't.
        let nUBatch = 512
        self.nBatch = nBatch
        self.batch  = llama_batch_init(Int32(nBatch), 0, 1)

        let nCores = ProcessInfo.processInfo.processorCount
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx           = UInt32(n_ctx)
        ctxParams.n_batch         = UInt32(nBatch)
        ctxParams.n_ubatch        = UInt32(nUBatch)
        ctxParams.n_threads       = Int32(max(1, nCores - 1))
        ctxParams.n_threads_batch = Int32(nCores)
        Self.applyMemoryParams(&ctxParams)

        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw LlamaError.contextInitFailed
        }
        self.context = ctx
        self.contextSize = n_ctx
        self.currentNPast = 0
    }

    /// Current token count in the KV cache
    var tokenCount: Int32 { currentNPast }

    /// Tokens per second from last generation
    var tokensPerSecond: Double {
        guard lastGenerationTime > 0 else { return 0 }
        return Double(lastGenerationTokens) / lastGenerationTime
    }

    init() {
        self.batch = llama_batch_init(512, 0, 1)  // placeholder; replaced in loadModel
    }

    func shutdown() {
        if let sampling { llama_sampler_free(sampling) }
        self.sampling = nil
        llama_batch_free(batch)
        self.batch = llama_batch_init(0, 0, 1)
        if let mtmdCtx { mtmd_free(mtmdCtx) }
        self.mtmdCtx = nil
        if let context { llama_free(context) }
        self.context = nil
        if let model { llama_model_free(model) }
        self.model = nil
        if isLoaded { llama_backend_free() }
        isLoaded = false
    }

    deinit {
    }

    /// Memory-critical context parameters shared by loadModel and reloadContext.
    ///
    /// THE big one is `swa_full`.  Gemma 4 uses hybrid sliding-window attention:
    /// 40 of its 48 layers only attend to a 1024-token window, and only 8 "global"
    /// layers need the full context.  llama.cpp's DEFAULT is `swa_full = true`, which
    /// allocates a *full-size* KV cache for the 40 sliding-window layers too — turning
    /// a ~9 GB cache at 128K into ~51 GB (every layer × full context).  This is the
    /// entire wired-memory blow-up; it scales with n_ctx and is independent of
    /// n_batch/n_ubatch, which is why tuning those did nothing.
    /// We only ever run a single sequence (n_seq_max == 1), so the performance caveat
    /// in the header note about swa_full=false does not apply to us.
    ///
    /// flash_attn AUTO additionally lets llama.cpp tile the global-layer attention so
    /// its compute scratch buffer stays small instead of materialising the full
    /// (n_ubatch × n_ctx × n_head) score matrix.
    private static func applyMemoryParams(_ p: inout llama_context_params) {
        p.swa_full        = false
        p.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
    }

    func loadModel(at path: String, mmProjPath: String?, n_ctx: Int32 = 32_768) throws {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999  // All layers on GPU — M1 Max 64GB has plenty of headroom

        guard let m = llama_model_load_from_file(path, modelParams) else {
            throw LlamaError.modelLoadFailed
        }
        self.model = m
        self.vocab = llama_model_get_vocab(m)

        let nBatch  = min(Int(n_ctx) / 8, 2048)
        // n_ubatch must be >= the vision encoder's tokens-per-image (256 for Gemma 4):
        // image embeddings decode non-causally in ONE physical batch, and llama.cpp
        // aborts with "non-causal attention requires n_ubatch >= n_tokens" if it can't.
        let nUBatch = 512
        self.nBatch = nBatch
        self.batch  = llama_batch_init(Int32(nBatch), 0, 1)

        let nCores = ProcessInfo.processInfo.processorCount  // M1 Max: 10
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx           = UInt32(n_ctx)
        ctxParams.n_batch         = UInt32(nBatch)
        ctxParams.n_ubatch        = UInt32(nUBatch)
        ctxParams.n_threads       = Int32(max(1, nCores - 1))
        ctxParams.n_threads_batch = Int32(nCores)
        Self.applyMemoryParams(&ctxParams)

        guard let ctx = llama_init_from_model(m, ctxParams) else {
            throw LlamaError.contextInitFailed
        }
        self.context = ctx

        if let mmProjPath {
            var mtmdParams = mtmd_context_params_default()
            mtmdParams.use_gpu = true
            mtmdParams.n_threads = Int32(nCores)
            let mtmd = mtmd_init_from_file(mmProjPath, UnsafeMutableRawPointer(m), mtmdParams)
            if let mtmd {
                self.mtmdCtx = mtmd
                self.hasVision = mtmd_support_vision(mtmd)
                self.hasAudio = mtmd_support_audio(mtmd)
            }
        }

        // Sampling params per Google's recommendation for Gemma 4
        self.sampling = Self.makeSamplerChain()


        isLoaded = true
    }

    enum GenerateResult {
        case finished
        case toolCall(rawOutput: String)
    }

    /// Generate with fresh context (clears KV cache)
    func generate(prompt: String, imageDatas: [Data], audioSamples: [Float]?, onToken: @Sendable (String) -> Void) throws -> GenerateResult {
        guard let context, let vocab, let sampling else {
            throw LlamaError.notLoaded
        }

        stopFlag.value = false
        llama_memory_clear(llama_get_memory(context), true)
        // Fresh sampler chain with new random seed — prevents identical outputs
        llama_sampler_free(sampling)
        self.sampling = Self.makeSamplerChain()
        temporaryInvalidCChars = []

        var nPast: Int32 = 0

        if let audioSamples, let mtmdCtx {
            try processMultimodalAudio(prompt: prompt, samples: audioSamples, mtmdCtx: mtmdCtx, nPast: &nPast)
        } else if !imageDatas.isEmpty, let mtmdCtx {
            try processMultimodal(prompt: prompt, imageDatas: imageDatas, mtmdCtx: mtmdCtx, nPast: &nPast)
        } else {
            let tokens = tokenize(text: prompt, addBos: true)
            if tokens.count > Int(contextSize) {
                throw LlamaError.promptTooLong
            }
            // Process prompt in chunks matching n_batch so we never exceed ctx capacity
            let batchSize = nBatch
            var offset = 0
            while offset < tokens.count {
                let chunkEnd = min(offset + batchSize, tokens.count)
                let isLastChunk = chunkEnd == tokens.count
                llama_batch_clear(&batch)
                for i in offset..<chunkEnd {
                    let isLast = isLastChunk && i == chunkEnd - 1
                    llama_batch_add(&batch, tokens[i], Int32(i), [0], isLast)
                }
                if llama_decode(context, batch) != 0 {
                    throw LlamaError.decodeFailed
                }
                offset = chunkEnd
            }
            nPast = Int32(tokens.count)
        }

        let result = try decodeLoop(nPast: &nPast, onToken: onToken)
        currentNPast = nPast
        return result
    }

    /// Continue generating after injecting tool response (no KV cache clear)
    func continueGeneration(text: String, onToken: @Sendable (String) -> Void) throws -> GenerateResult {
        guard let context, let sampling else {
            throw LlamaError.notLoaded
        }

        llama_sampler_free(sampling)
        self.sampling = Self.makeSamplerChain()
        temporaryInvalidCChars = []

        let tokens = tokenize(text: text, addBos: false)
        var nPast = currentNPast

        let batchSize = nBatch
        var offset = 0
        while offset < tokens.count {
            let chunkEnd = min(offset + batchSize, tokens.count)
            let isLastChunk = chunkEnd == tokens.count
            llama_batch_clear(&batch)
            for i in offset..<chunkEnd {
                let isLast = isLastChunk && i == chunkEnd - 1
                llama_batch_add(&batch, tokens[i], nPast + Int32(i), [0], isLast)
            }
            if llama_decode(context, batch) != 0 {
                throw LlamaError.decodeFailed
            }
            offset = chunkEnd
        }
        nPast += Int32(tokens.count)

        let result = try decodeLoop(nPast: &nPast, onToken: onToken)
        currentNPast = nPast
        return result
    }

    private func decodeLoop(nPast: inout Int32, onToken: @Sendable (String) -> Void) throws -> GenerateResult {
        guard let context, let vocab, let sampling else {
            throw LlamaError.notLoaded
        }

        let nLen: Int32 = contextSize   // respect the actual context window, not a hardcoded 8K cap
        var outputParts: [String] = []
        var recentBuffer = ""
        var generatedTokens = 0
        let startTime = CFAbsoluteTimeGetCurrent()

        func saveTiming() {
            lastGenerationTokens = generatedTokens
            lastGenerationTime = CFAbsoluteTimeGetCurrent() - startTime
        }

        while nPast < nLen {
            if stopFlag.value {
                stopFlag.value = false
                saveTiming()
                return .finished
            }

            let newTokenId = llama_sampler_sample(sampling, context, -1)
            generatedTokens += 1

            if llama_vocab_is_eog(vocab, newTokenId) {
                if !temporaryInvalidCChars.isEmpty {
                    let s = String(cString: temporaryInvalidCChars + [0])
                    temporaryInvalidCChars.removeAll()
                    onToken(s)
                }
                saveTiming()
                return .finished
            }

            let piece = tokenToPiece(token: newTokenId)
            temporaryInvalidCChars.append(contentsOf: piece)

            if let string = String(validatingUTF8: temporaryInvalidCChars + [0]) {
                temporaryInvalidCChars.removeAll()
                outputParts.append(string)
                onToken(string)

                recentBuffer += string
                if recentBuffer.count > 30 {
                    recentBuffer = String(recentBuffer.suffix(20))
                }
                if recentBuffer.contains("<tool_call|>") {
                    saveTiming()
                    return .toolCall(rawOutput: outputParts.joined())
                }
            }

            llama_batch_clear(&batch)
            llama_batch_add(&batch, newTokenId, nPast, [0], true)
            nPast += 1

            if llama_decode(context, batch) != 0 {
                throw LlamaError.decodeFailed
            }

            // Quiet mode (Boost off, the default): rest 80ms between tokens so
            // the GPU duty-cycles instead of running flat out — ~10-12 t/s,
            // cool and fanless. Emil reads at that speed anyway; Boost is the
            // opt-in full-speed (~27 t/s cold) mode for when output is long.
            if !boostMode {
                usleep(80_000)
            }
        }

        saveTiming()
        return .finished
    }

    private func processMultimodal(prompt: String, imageDatas: [Data], mtmdCtx: OpaquePointer, nPast: inout Int32) throws {
        guard let context else { throw LlamaError.notLoaded }
        guard !imageDatas.isEmpty else { return }

        // Create one bitmap per image; free all on exit
        var bitmaps: [OpaquePointer] = []
        defer { bitmaps.forEach { mtmd_bitmap_free($0) } }

        for data in imageDatas {
            let bm: OpaquePointer? = data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                return mtmd_helper_bitmap_init_from_buf(mtmdCtx, base, ptr.count, false)
            }
            guard let bm else { throw LlamaError.imageProcessingFailed }
            bitmaps.append(bm)
        }

        // Insert one marker per image before the user text (Google recommends images first)
        let marker = String(cString: mtmd_default_marker())
        let promptWithMarkers: String
        if prompt.contains(marker) {
            promptWithMarkers = prompt   // caller already placed markers
        } else {
            let markerBlock = (0..<bitmaps.count).map { _ in marker }.joined(separator: "\n") + "\n"
            if let range = prompt.range(of: "<|turn>user\n", options: .backwards) {
                promptWithMarkers = String(prompt[..<range.upperBound]) + markerBlock + String(prompt[range.upperBound...])
            } else {
                promptWithMarkers = markerBlock + prompt
            }
        }

        guard let chunks = mtmd_input_chunks_init() else { throw LlamaError.imageProcessingFailed }
        defer { mtmd_input_chunks_free(chunks) }

        let cStr = promptWithMarkers.cString(using: .utf8)!
        var bitmapPtrs: [OpaquePointer?] = bitmaps.map { Optional($0) }
        let result: Int32 = cStr.withUnsafeBufferPointer { textBuf in
            var inputText = mtmd_input_text()
            inputText.text = textBuf.baseAddress
            inputText.add_special = true
            inputText.parse_special = true
            return bitmapPtrs.withUnsafeMutableBufferPointer { bPtr in
                mtmd_tokenize(mtmdCtx, chunks, &inputText, bPtr.baseAddress, bitmaps.count)
            }
        }
        if result != 0 { throw LlamaError.imageProcessingFailed }

        var newNPast: Int32 = 0
        let evalResult = mtmd_helper_eval_chunks(mtmdCtx, UnsafeMutableRawPointer(context), chunks, 0, 0, 512, true, &newNPast)
        if evalResult != 0 { throw LlamaError.decodeFailed }
        nPast = newNPast
    }

    private func processMultimodalAudio(prompt: String, samples: [Float], mtmdCtx: OpaquePointer, nPast: inout Int32) throws {
        guard let context else { throw LlamaError.notLoaded }

        let bitmap: OpaquePointer? = samples.withUnsafeBufferPointer { buf in
            return mtmd_bitmap_init_from_audio(buf.count, buf.baseAddress)
        }
        guard let bitmap else {
            throw LlamaError.audioProcessingFailed
        }
        defer { mtmd_bitmap_free(bitmap) }

        // Gemma 4 model card: audio goes AFTER text, inside the user turn.
        // Find the last <turn|> (closing of the most recent user turn) and
        // insert the audio marker just before it so order is: text → audio → <turn|>
        let marker = String(cString: mtmd_default_marker())
        let promptWithMarker: String
        if prompt.contains(marker) {
            promptWithMarker = prompt   // caller already placed the marker
        } else if let range = prompt.range(of: "<turn|>", options: .backwards) {
            promptWithMarker = String(prompt[..<range.lowerBound]) + "\n" + marker + "\n" + String(prompt[range.lowerBound...])
        } else if let modelRange = prompt.range(of: "<|turn>model\n", options: .backwards) {
            // Fallback: no closing turn token found, insert before model start
            promptWithMarker = String(prompt[..<modelRange.lowerBound]) + marker + "\n" + String(prompt[modelRange.lowerBound...])
        } else {
            promptWithMarker = prompt + "\n" + marker
        }

        guard let chunks = mtmd_input_chunks_init() else {
            throw LlamaError.audioProcessingFailed
        }
        defer { mtmd_input_chunks_free(chunks) }

        let cString = promptWithMarker.cString(using: .utf8)!
        let result: Int32 = cString.withUnsafeBufferPointer { textBuf in
            var inputText = mtmd_input_text()
            inputText.text = textBuf.baseAddress
            inputText.add_special = true
            inputText.parse_special = true

            var bitmapPtr: OpaquePointer? = bitmap
            return withUnsafeMutablePointer(to: &bitmapPtr) { bPtr in
                return mtmd_tokenize(mtmdCtx, chunks, &inputText, bPtr, 1)
            }
        }

        if result != 0 {
            throw LlamaError.audioProcessingFailed
        }

        var newNPast: Int32 = 0
        let evalResult = mtmd_helper_eval_chunks(mtmdCtx, UnsafeMutableRawPointer(context), chunks, 0, 0, 512, true, &newNPast)
        if evalResult != 0 {
            throw LlamaError.decodeFailed
        }
        nPast = newNPast
    }

    /// Stop can be called from any thread via the atomic flag
    nonisolated func stop() {
        stopFlag.value = true
    }

    func clear() {
        guard let context else { return }
        temporaryInvalidCChars.removeAll()
        llama_memory_clear(llama_get_memory(context), true)
    }

    /// Build a fresh sampler chain with a new random seed.
    /// Called at init and before every generation so each response is truly random.
    private static func makeSamplerChain() -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)!
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(64))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(1.0))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        return chain
    }

    private func tokenize(text: String, addBos: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8Count = text.utf8.count
        let nTokens = utf8Count + (addBos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: nTokens)
        let count = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(nTokens), addBos, false)
        var result: [llama_token] = []
        for i in 0..<count {
            result.append(tokens[Int(i)])
        }
        tokens.deallocate()
        return result
    }

    private func tokenToPiece(token: llama_token) -> [CChar] {
        guard let vocab else { return [] }
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        buf.initialize(repeating: 0, count: 8)
        defer { buf.deallocate() }

        let n = llama_token_to_piece(vocab, token, buf, 8, 0, false)
        if n < 0 {
            let bigger = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-n))
            bigger.initialize(repeating: 0, count: Int(-n))
            defer { bigger.deallocate() }
            let n2 = llama_token_to_piece(vocab, token, bigger, -n, 0, false)
            return Array(UnsafeBufferPointer(start: bigger, count: Int(n2)))
        }
        return Array(UnsafeBufferPointer(start: buf, count: Int(n)))
    }
}

private func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seqIds: [llama_seq_id], _ logits: Bool) {
    batch.token[Int(batch.n_tokens)] = id
    batch.pos[Int(batch.n_tokens)] = pos
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(seqIds.count)
    for i in 0..<seqIds.count {
        batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seqIds[i]
    }
    batch.logits[Int(batch.n_tokens)] = logits ? 1 : 0
    batch.n_tokens += 1
}

enum LlamaError: Error, LocalizedError {
    case modelLoadFailed
    case contextInitFailed
    case notLoaded
    case decodeFailed
    case imageProcessingFailed
    case audioProcessingFailed
    case promptTooLong

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: "Failed to load the model file"
        case .contextInitFailed: "Failed to initialize inference context"
        case .notLoaded: "Model not loaded"
        case .decodeFailed: "Token decoding failed"
        case .imageProcessingFailed: "Failed to process image"
        case .audioProcessingFailed: "Failed to process audio"
        case .promptTooLong: "Conversation too long for context window"
        }
    }
}
