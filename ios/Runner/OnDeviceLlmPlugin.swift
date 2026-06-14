import Flutter
import UIKit
import UserNotifications

// On-device LLM for script structuring. Primary runtime: Gemma 4 E2B (QAT
// q4_0 GGUF) via llama.cpp (prebuilt xcframework, Metal-accelerated). Falls
// back to Apple's Foundation Models when no GGUF is downloaded.
import llama

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Flutter platform channel for on-device script structuring.
/// Talks over `com.lineguide/on_device_llm`; prefers a downloaded Gemma 4 GGUF
/// (run through llama.cpp, loaded lazily and reused across chunks) and falls
/// back to Apple's built-in model. `initialize` returns `{ ready, runtime,
/// error }` so the Dart side can log what's going on.
class OnDeviceLlmPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var isReady = false
    private var useFoundationModels = false
    private var ggufPath: String?

    // Background-task assertion held across a long cleanup so a brief app-switch
    // doesn't immediately suspend mid-chunk. iOS still caps the grace window.
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    // llama.cpp handles — loaded once on first generate, reused for every chunk
    // (the model is multi-GB; reloading per chunk would be ruinous). The KV
    // cache is cleared between chunks so each one is structured independently.
    private var model: OpaquePointer?
    private var vocab: OpaquePointer?
    private var backendReady = false

    // A multi-sequence context reused across all batches of one cleanup job.
    // Recreating a large context per batch fragments/leaks Metal memory (the
    // last batch's decode fails and the post-job reload OOMs); reusing one and
    // clearing its KV between batches avoids that.
    private var batchCtx: OpaquePointer?
    private var batchCtxN: Int = 0

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/on_device_llm",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            Task { await initialize(call: call, result: result) }
        case "generate":
            Task { await generate(call: call, result: result) }
        case "generateBatch":
            Task { await generateBatch(call: call, result: result) }
        case "dispose":
            dispose(result: result)
        case "beginBackground":
            beginBackground(call: call, result: result)
        case "endBackground":
            endBackground(result: result)
        case "notify":
            postNotification(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Log to both the system log and the Flutter debug log (via the channel),
    /// so progress through a long model load/generate is visible in-app.
    private func report(_ message: String) {
        NSLog("OnDeviceLlm: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("onLog", arguments: message)
        }
    }

    /// Push absolute chunk-completion progress to Dart so the import screen's
    /// progress bar advances per chunk even though one native call now decodes a
    /// whole group of chunks (continuous batching).
    private func reportBatchProgress(_ done: Int, _ total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("onBatchProgress", arguments: ["done": done, "total": total])
        }
    }

    // MARK: - Init (cheap — the GGUF loads on first generate)

    private func initialize(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        // 1. Gemma 4 GGUF present → use llama.cpp (loads on first use).
        if let path = validatedGgufPath(call: call) {
            ggufPath = path
            useFoundationModels = false
            isReady = true
            NSLog("OnDeviceLlm: Gemma 4 GGUF present (loads on first use)")
            result(["ready": true, "runtime": "gemma", "error": ""])
            return
        }

        // 2. Apple's built-in on-device model — no download required.
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            if case .available = availability {
                useFoundationModels = true
                isReady = true
                NSLog("OnDeviceLlm: using Apple Foundation Models")
                result(["ready": true, "runtime": "foundation", "error": ""])
                return
            }
            isReady = false
            result(["ready": false, "runtime": "none",
                    "error": "no gemma gguf; foundationModels: \(availability)"])
            return
        }
        #endif

        isReady = false
        result(["ready": false, "runtime": "none", "error": "no on-device runtime"])
    }

    /// Resolve the GGUF file inside the supplied model directory, confined to
    /// Documents/models (symlink-resolved) to block path traversal. Returns the
    /// `.gguf` path or nil. We pick the largest `.gguf` so the multimodal
    /// projector (mmproj) sidecar, if ever present, is never chosen as the LM.
    private func validatedGgufPath(call: FlutterMethodCall) -> String? {
        guard let args = call.arguments as? [String: Any],
              let rawPath = args["modelPath"] as? String, !rawPath.isEmpty else {
            return nil
        }
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        let allowedBase = (((docsDir as NSString)
            .appendingPathComponent("models")) as NSString).resolvingSymlinksInPath
        let dir = ((rawPath as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        guard dir == allowedBase || dir.hasPrefix(allowedBase + "/") else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (path: String, size: Int)?
        for name in entries where name.hasSuffix(".gguf") && !name.contains("mmproj") {
            let full = (dir as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? Int) ?? 0
            if best == nil || size > best!.size {
                best = (full, size)
            }
        }
        return best?.path
    }

    // MARK: - Generate (Gemma loads lazily here)

    private func generate(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let prompt = args["prompt"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "prompt required", details: nil))
            return
        }
        _ = args["imagePaths"] as? [String]  // reserved for the multimodal path

        guard isReady else {
            result(FlutterError(code: "NOT_READY", message: "Model not initialized", details: nil))
            return
        }

        if let path = ggufPath, !useFoundationModels {
            do {
                let text = try runLlama(prompt: prompt, modelPath: path)
                result(text)
            } catch {
                report("gemma: failed — \(error.localizedDescription)")
                result(FlutterError(code: "GENERATE_FAILED", message: error.localizedDescription, details: nil))
            }
            return
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), useFoundationModels {
            do {
                report("foundation: generating…")
                let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: 1500)
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt, options: options)
                report("foundation: done — \(response.content.count) chars")
                result(response.content)
            } catch {
                report("foundation: failed — \(error.localizedDescription)")
                result(FlutterError(code: "GENERATE_FAILED", message: error.localizedDescription, details: nil))
            }
            return
        }
        #endif

        result(FlutterError(code: "NOT_IMPLEMENTED", message: "No on-device runtime.", details: nil))
    }

    // MARK: - llama.cpp generation

    private enum LlamaError: LocalizedError {
        case loadFailed, contextFailed, decodeFailed
        var errorDescription: String? {
            switch self {
            case .loadFailed: return "Failed to load GGUF model"
            case .contextFailed: return "Failed to create llama context"
            case .decodeFailed: return "llama_decode failed"
            }
        }
    }

    /// Run one structuring completion through llama.cpp. The model/context are
    /// loaded once and reused; only the KV cache is cleared per call so chunks
    /// stay independent. Deterministic (greedy) for stable JSON.
    private func runLlama(prompt: String, modelPath: String) throws -> String {
        if !backendReady {
            llama_backend_init()
            backendReady = true
        }

        if model == nil {
            report("gemma: loading model weights (≈3.3 GB)…")
            var mparams = llama_model_default_params()
            #if targetEnvironment(simulator)
            mparams.n_gpu_layers = 0
            #else
            mparams.n_gpu_layers = 99  // offload all layers to Metal on device
            #endif
            guard let m = llama_model_load_from_file(modelPath, mparams) else {
                throw LlamaError.loadFailed
            }
            model = m
            vocab = llama_model_get_vocab(m)
            report("gemma: model loaded")
        }
        guard let model = model, let vocab = vocab else { throw LlamaError.loadFailed }

        // Fresh context per chunk. Resetting the KV cache in place between
        // generations (llama_memory_clear) did not reliably reset the position
        // state, so the cache filled up across chunks until llama_decode
        // returned 1 ("no KV slot") and every later chunk failed. A new context
        // guarantees a clean slate; the heavy 3.3 GB model stays loaded and is
        // reused, so this is cheap.
        var cparams = llama_context_default_params()
        // Sized for large structuring windows (~150 source lines/chunk): the
        // prompt (schema + chunk) plus the generated JSON must both fit in
        // n_ctx. n_batch is the LOGICAL cap on tokens submitted to one
        // llama_decode — below the prompt size, llama_decode hits
        // GGML_ASSERT(n_tokens <= n_batch) and aborts (SIGABRT), so keep it at
        // n_ctx. n_ubatch (the PHYSICAL batch that sizes the compute buffer)
        // stays small so memory stays low regardless of window size.
        cparams.n_ctx = 8192
        cparams.n_batch = 8192
        cparams.n_ubatch = 512
        guard let ctx = llama_init_from_model(model, cparams) else {
            throw LlamaError.contextFailed
        }
        defer { llama_free(ctx) }

        // Gemma 4 turn format (from the GGUF's own chat template). <bos> is
        // added by the tokenizer (add_special); <|turn>/<turn|> are parsed as
        // special tokens (parse_special).
        let formatted = "<|turn>user\n\(prompt)<turn|>\n<|turn>model\n"

        // Tokenize. Token count never exceeds byte count, so this buffer is safe.
        let nMax = Int32(formatted.utf8.count + 8)
        var tokens = [llama_token](repeating: 0, count: Int(nMax))
        let nTok = formatted.withCString { cstr in
            llama_tokenize(vocab, cstr, Int32(formatted.utf8.count), &tokens, nMax, true, true)
        }
        guard nTok > 0 else { throw LlamaError.decodeFailed }
        tokens = Array(tokens.prefix(Int(nTok)))

        report("gemma: generating…")
        var rc = tokens.withUnsafeMutableBufferPointer { bp -> Int32 in
            llama_decode(ctx, llama_batch_get_one(bp.baseAddress, Int32(bp.count)))
        }
        if rc != 0 { throw LlamaError.decodeFailed }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }

        let maxNewTokens = 4096  // large window → more JSON per chunk
        var outBytes = [UInt8]()
        var generated = 0
        var cur: llama_token = 0
        var pieceBuf = [CChar](repeating: 0, count: 256)
        while generated < maxNewTokens {
            cur = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, cur) { break }
            // special=false → real text only (turn markers render to nothing)
            let n = llama_token_to_piece(vocab, cur, &pieceBuf, Int32(pieceBuf.count), 0, false)
            if n > 0 {
                for i in 0..<Int(n) { outBytes.append(UInt8(bitPattern: pieceBuf[i])) }
            }
            generated += 1
            if generated % 16 == 0 { report("gemma: generating… \(generated) tokens") }
            rc = withUnsafeMutablePointer(to: &cur) { p -> Int32 in
                llama_decode(ctx, llama_batch_get_one(p, 1))
            }
            if rc != 0 { break }
        }

        let text = String(decoding: outBytes, as: UTF8.self)
        report("gemma: done — \(generated) tokens, \(text.count) chars")
        return text
    }

    // MARK: - Batched (parallel) generation

    /// Decode N independent prompts in parallel. On-device generation is
    /// memory-bandwidth-bound (each step reads the whole 3.3 GB of weights), so
    /// batching N sequences yields ~N tokens per weight-read — a near-linear
    /// throughput win until the GPU becomes compute-bound. Returns N outputs in
    /// input order (a sequence that errors yields "").
    private func generateBatch(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let prompts = args["prompts"] as? [String], !prompts.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "prompts required", details: nil))
            return
        }
        guard isReady else {
            result(FlutterError(code: "NOT_READY", message: "Model not initialized", details: nil))
            return
        }
        // `slots` = how many sequences to keep in flight at once; the call may
        // carry more prompts than slots (continuous batching refills a slot the
        // instant its chunk finishes). Defaults to one slot per prompt.
        let slots = (args["slots"] as? Int) ?? prompts.count
        // For live progress: the chunk offset of this group within the whole job
        // and the total chunk count, so onBatchProgress reports absolute numbers.
        let baseDone = (args["baseDone"] as? Int) ?? 0
        let totalChunks = (args["totalChunks"] as? Int) ?? prompts.count
        if let path = ggufPath, !useFoundationModels {
            do {
                let outs = try runLlamaBatch(prompts: prompts, slots: slots,
                                             baseDone: baseDone, totalChunks: totalChunks,
                                             modelPath: path)
                result(outs)
            } catch {
                report("gemma: batch failed — \(error.localizedDescription)")
                // The context is suspect after a decode failure — drop it so the
                // next batch rebuilds a clean one instead of failing forever.
                freeBatchCtx()
                result(FlutterError(code: "GENERATE_FAILED", message: error.localizedDescription, details: nil))
            }
            return
        }
        // No batched path for Foundation Models — Dart falls back to sequential.
        result(FlutterError(code: "NOT_IMPLEMENTED", message: "No batched runtime.", details: nil))
    }

    /// Continuous batching: keep `slots` sequences decoding at once, and the
    /// instant one chunk hits EOG, refill its slot with the next pending chunk
    /// (rather than waiting for the whole batch to finish). This removes the
    /// tail-latency of fixed batching — where the batch runs at the speed of its
    /// single longest chunk — so the GPU stays saturated end-to-end. One call
    /// may carry many more `prompts` than `slots`; outputs are returned in input
    /// order ("" for a chunk that errors).
    private func runLlamaBatch(prompts: [String], slots requestedSlots: Int,
                               baseDone: Int, totalChunks: Int,
                               modelPath: String) throws -> [String] {
        if !backendReady { llama_backend_init(); backendReady = true }
        if model == nil {
            report("gemma: loading model weights (≈3.3 GB)…")
            var mparams = llama_model_default_params()
            #if targetEnvironment(simulator)
            mparams.n_gpu_layers = 0
            #else
            mparams.n_gpu_layers = 99
            #endif
            guard let m = llama_model_load_from_file(modelPath, mparams) else {
                throw LlamaError.loadFailed
            }
            model = m
            vocab = llama_model_get_vocab(m)
            report("gemma: model loaded")
        }
        guard let model = model, let vocab = vocab else { throw LlamaError.loadFailed }

        let n = prompts.count
        let nSlots = max(1, min(requestedSlots, n))
        let perSeqCtx: UInt32 = 4096
        let maxNewTokens = 2048

        // Reuse one context sized for `nSlots` concurrent sequences across the
        // whole job (recreating a large multi-seq context per call fragments
        // Metal memory). n_ctx is the TOTAL KV cells across sequences; n_ubatch
        // stays small so the compute buffer doesn't grow with the slot count.
        if batchCtx == nil || batchCtxN < nSlots {
            if let old = batchCtx { llama_free(old); batchCtx = nil }
            var cparams = llama_context_default_params()
            cparams.n_ctx = perSeqCtx * UInt32(nSlots)
            cparams.n_batch = cparams.n_ctx
            cparams.n_ubatch = 512
            cparams.n_seq_max = UInt32(nSlots)
            guard let c = llama_init_from_model(model, cparams) else {
                throw LlamaError.contextFailed
            }
            batchCtx = c
            batchCtxN = nSlots
            report("gemma: batch ctx created (slots=\(nSlots), ctx=\(cparams.n_ctx))")
        }
        guard let ctx = batchCtx else { throw LlamaError.contextFailed }
        let mem = llama_get_memory(ctx)
        // Clean slate. Per-token positions are assigned explicitly below, so a
        // clear that doesn't reset auto-position state is still safe.
        llama_memory_clear(mem, true)

        // Tokenize every prompt up front with the Gemma 4 turn template.
        var tokensPerSeq = [[llama_token]]()
        var maxChunkTokens = 0
        for p in prompts {
            let formatted = "<|turn>user\n\(p)<turn|>\n<|turn>model\n"
            let nMax = Int32(formatted.utf8.count + 8)
            var toks = [llama_token](repeating: 0, count: Int(nMax))
            let nt = formatted.withCString { cstr in
                llama_tokenize(vocab, cstr, Int32(formatted.utf8.count), &toks, nMax, true, true)
            }
            guard nt > 0 else { throw LlamaError.decodeFailed }
            toks = Array(toks.prefix(Int(nt)))
            tokensPerSeq.append(toks)
            maxChunkTokens = max(maxChunkTokens, toks.count)
        }

        // Greedy sampling is stateless, so one sampler serves all slots.
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }

        // One batch buffer reused for both prefill (≤ maxChunkTokens tokens) and
        // each generation step (≤ nSlots tokens).
        var batch = llama_batch_init(Int32(max(nSlots, maxChunkTokens)), 0, Int32(nSlots))
        defer { llama_batch_free(batch) }

        // Per-slot state. A slot maps to exactly one chunk while active.
        var slotChunk = [Int](repeating: -1, count: nSlots)   // chunk index in this slot
        var slotPos = [Int32](repeating: 0, count: nSlots)     // KV position (= tokens consumed)
        var slotPromptLen = [Int](repeating: 0, count: nSlots) // prompt length, for the gen cap
        var slotNext = [llama_token](repeating: 0, count: nSlots) // token to emit+feed next
        var slotActive = [Bool](repeating: false, count: nSlots)

        var outBytes = [[UInt8]](repeating: [], count: n)
        var pieceBuf = [CChar](repeating: 0, count: 256)

        // Prefill chunk `c` into slot `s`: clear the slot's KV, decode the whole
        // prompt in one shot, and sample the first generated token. Issues its
        // own llama_decode, so it must never run mid-construction of the shared
        // generation batch — refills are deferred to after the gen decode below.
        func loadSlot(_ s: Int, _ c: Int) throws {
            llama_memory_seq_rm(mem, Int32(s), -1, -1)
            let toks = tokensPerSeq[c]
            for (j, t) in toks.enumerated() {
                batch.token[j] = t
                batch.pos[j] = Int32(j)
                batch.n_seq_id[j] = 1
                batch.seq_id[j]![0] = Int32(s)
                batch.logits[j] = (j == toks.count - 1) ? 1 : 0
            }
            batch.n_tokens = Int32(toks.count)
            if llama_decode(ctx, batch) != 0 { throw LlamaError.decodeFailed }
            slotNext[s] = llama_sampler_sample(sampler, ctx, Int32(toks.count - 1))
            slotChunk[s] = c
            slotPromptLen[s] = toks.count
            slotPos[s] = Int32(toks.count)
            slotActive[s] = true
        }

        // Initial fill: assign the first nSlots chunks.
        var nextChunk = 0
        var doneCount = 0
        for s in 0..<nSlots where nextChunk < n {
            try loadSlot(s, nextChunk)
            nextChunk += 1
        }
        report("gemma: continuous batch — \(n) chunks, \(nSlots) slots, footprint \(footprintMB()) MB")

        var step = 0
        var ctxBroken = false
        while doneCount < n {
            // Phase 1: build the generation batch from active slots; collect the
            // ones that finish this step (do NOT refill yet — that reuses `batch`).
            var b = 0
            var seqOrder = [Int]()
            var toRefill = [Int]()
            for s in 0..<nSlots where slotActive[s] {
                let t = slotNext[s]
                let overLimit = Int(slotPos[s]) - slotPromptLen[s] >= maxNewTokens
                if llama_vocab_is_eog(vocab, t) || overLimit {
                    doneCount += 1
                    slotActive[s] = false
                    toRefill.append(s)
                    reportBatchProgress(baseDone + doneCount, totalChunks)
                    continue
                }
                let np = llama_token_to_piece(vocab, t, &pieceBuf, Int32(pieceBuf.count), 0, false)
                if np > 0 { for k in 0..<Int(np) { outBytes[slotChunk[s]].append(UInt8(bitPattern: pieceBuf[k])) } }
                batch.token[b] = t
                batch.pos[b] = slotPos[s]
                batch.n_seq_id[b] = 1
                batch.seq_id[b]![0] = Int32(s)
                batch.logits[b] = 1
                slotPos[s] += 1
                seqOrder.append(s)
                b += 1
            }

            // Phase 2: decode the generation step and sample each slot's next token.
            if b > 0 {
                batch.n_tokens = Int32(b)
                if llama_decode(ctx, batch) != 0 { ctxBroken = true; break }
                for (k, s) in seqOrder.enumerated() {
                    slotNext[s] = llama_sampler_sample(sampler, ctx, Int32(k))
                }
                step += 1
                if step % 16 == 0 {
                    report("gemma: continuous batch — step \(step), \(doneCount)/\(n) chunks done")
                }
            }

            // Phase 3: now that `batch` is free, refill each freed slot with the
            // next pending chunk (each loadSlot runs its own prefill decode).
            for s in toRefill where nextChunk < n {
                try loadSlot(s, nextChunk)
                nextChunk += 1
            }

            // Nothing decoded and nothing active left → finished.
            if b == 0 && !slotActive.contains(true) { break }
        }

        // A generation decode failed mid-group: keep the chunks that did finish
        // (returned below), but drop the now-suspect context so the next group
        // starts clean rather than cascading instant failures.
        if ctxBroken { freeBatchCtx() }

        report("gemma: continuous batch done — \(n) chunks, \(step) steps, footprint \(footprintMB()) MB")
        return outBytes.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Tear down the reusable multi-sequence context. Called on dispose and,
    /// critically, after any llama_decode failure: a failed decode leaves the
    /// context in a state where every subsequent decode also fails instantly, so
    /// the next batch must start from a freshly created context instead of
    /// cascading the whole job into "llama_decode failed" for every remaining
    /// chunk. The heavy 3.3 GB model stays loaded, so recreating the (small)
    /// context is cheap.
    private func freeBatchCtx() {
        if let c = batchCtx { llama_free(c) }
        batchCtx = nil
        batchCtxN = 0
    }

    /// Current resident memory footprint in MB (for tuning batch size).
    private func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) / (1024 * 1024) : -1
    }

    private func dispose(result: @escaping FlutterResult) {
        freeBatchCtx()
        if let model = model { llama_model_free(model) }
        model = nil
        vocab = nil
        useFoundationModels = false
        isReady = false
        NSLog("OnDeviceLlm: disposed")
        result(nil)
    }

    // MARK: - Background execution + notifications

    /// Hold a background-task assertion for the duration of a long cleanup. iOS
    /// grants only a short grace window, so this lets a quick app-switch not
    /// kill the job — it can't run for minutes fully backgrounded. Idempotent.
    private func beginBackground(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let reason = (call.arguments as? [String: Any])?["reason"] as? String ?? "task"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { result(nil); return }
            if self.bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTaskId)
            }
            self.bgTaskId = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
                guard let self = self else { return }
                if self.bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(self.bgTaskId)
                    self.bgTaskId = .invalid
                }
            }
            result(nil)
        }
    }

    private func endBackground(result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { result(nil); return }
            if self.bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTaskId)
                self.bgTaskId = .invalid
            }
            result(nil)
        }
    }

    /// Post a local notification (e.g. "cleanup complete"). Requests auth on
    /// first use; if the user declined, this quietly does nothing. Local
    /// notifications need no entitlement, only runtime authorization.
    private func postNotification(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let title = args?["title"] as? String ?? "CastCircle"
        let body = args?["body"] as? String ?? ""
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "script-ai-\(title.hashValue)",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
        result(nil)
    }
}
