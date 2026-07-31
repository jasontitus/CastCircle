import Foundation
import AVFoundation
import CryptoKit
import UIKit
import MLX
import MLXUtilsLibrary

/// On-device Kokoro TTS service using MLX for Apple Silicon inference.
///
/// Uses the KokoroSwift package (mlalma/kokoro-ios) which runs Kokoro-82M
/// entirely on-device via Apple's MLX framework.
class KokoroMLXService {

    // MARK: - Voice catalogue

    /// Available Kokoro voice IDs. Each maps to a pre-trained voice style.
    static let availableVoices: [String] = [
        // American Female
        "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica",
        "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        // American Male
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck",
        // British Female
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        // British Male
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    // MARK: - State

    private var ttsEngine: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    /// Serial actor to prevent concurrent synthesis (NLTagger is not thread-safe).
    private let synthQueue = DispatchQueue(label: "com.castcircle.kokoro-synth")
    /// Incremented on each synthesize call; older calls bail out early.
    private var synthGeneration: Int = 0

    var isModelLoaded: Bool { ttsEngine != nil && !voices.isEmpty }

    var isModelDownloaded: Bool {
        let modelURL = modelDirectory.appendingPathComponent("kokoro-v1_0.safetensors")
        let voicesURL = modelDirectory.appendingPathComponent("voices.npz")
        return FileManager.default.fileExists(atPath: modelURL.path)
            && FileManager.default.fileExists(atPath: voicesURL.path)
    }

    // MARK: - Background state

    /// Set from app lifecycle notifications so work already queued on
    /// `synthQueue` can re-check before submitting GPU work. `applicationState`
    /// is main-thread-only, so it can't be read from the synth queue directly.
    private static let bgLock = NSLock()
    private static var _isBackgrounded = false
    static var isBackgrounded: Bool {
        bgLock.lock(); defer { bgLock.unlock() }
        return _isBackgrounded
    }
    private static func setBackgrounded(_ value: Bool) {
        bgLock.lock(); _isBackgrounded = value; bgLock.unlock()
    }

    init() {
        observeAppLifecycle()
        // Seed from the current state in case the service is created while
        // the app is already in the background.
        if Thread.isMainThread {
            Self.setBackgrounded(UIApplication.shared.applicationState == .background)
        } else {
            DispatchQueue.main.async {
                Self.setBackgrounded(UIApplication.shared.applicationState == .background)
            }
        }
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil) { _ in Self.setBackgrounded(true) }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: nil) { _ in Self.setBackgrounded(false) }
    }

    // MARK: - Model lifecycle

    /// Load the Kokoro MLX model from the app's documents directory.
    func loadModel() async throws {
        if ttsEngine != nil { return }

        let modelURL = modelDirectory.appendingPathComponent("kokoro-v1_0.safetensors")
        let voicesURL = modelDirectory.appendingPathComponent("voices.npz")

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw KokoroError.modelNotDownloaded
        }
        guard FileManager.default.fileExists(atPath: voicesURL.path) else {
            throw KokoroError.voicesNotDownloaded
        }

        // Load TTS engine. A corrupt/truncated weights file used to `try!`
        // crash here on EVERY launch; now the bad file is deleted so the
        // AI-models screen offers the download again.
        do {
            ttsEngine = try KokoroTTS(modelPath: modelURL)
        } catch {
            try? FileManager.default.removeItem(at: modelURL)
            throw KokoroError.modelCorrupt(String(describing: error))
        }

        // Load voice embeddings from NPZ file
        voices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
        if voices.isEmpty {
            ttsEngine = nil
            throw KokoroError.voicesNotDownloaded
        }

        // NOTE: deliberately no AVAudioSession configuration here. The shared
        // session is owned by whoever is actively capturing/playing; the Dart
        // side (PlaybackSession.ensurePlayback) sets .playback right before
        // audio is played. Flipping it here breaks a live STT session.
    }

    /// Unload the model from memory without deleting files.
    /// Call this when TTS is not needed to reduce memory pressure.
    func unloadModel() {
        ttsEngine = nil
        voices = [:]
        Memory.clearCache()
        NSLog("KokoroMLX: Model unloaded, MLX cache cleared")
    }

    /// Delete downloaded model weights to free storage.
    func deleteModel() throws {
        ttsEngine = nil
        voices = [:]
        Memory.clearCache()
        let dir = modelDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Synthesis

    /// Synthesize speech and return the path to a WAV file.
    /// Serialized to prevent concurrent NLTagger/MLX access which causes SIGSEGV.
    func synthesize(text: String, voice: String, speed: Float) async throws -> String {
        guard let ttsEngine = ttsEngine else {
            throw KokoroError.modelNotLoaded
        }

        // Look up voice embedding — voice names in the NPZ have ".npy" suffix
        let voiceKey = voice + ".npy"
        guard let voiceEmbedding = voices[voiceKey] else {
            throw KokoroError.voiceNotFound(voice)
        }

        // Cache hit: the key is a stable digest, so a line synthesized in ANY
        // previous session (same text/voice/speed) plays with zero synthesis
        // latency. Touch the file's date so pruning is LRU.
        pruneCacheIfNeeded()
        let cachedPath = cacheURL(for: text, voice: voice, speed: speed)
        if FileManager.default.fileExists(atPath: cachedPath.path) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: cachedPath.path)
            return cachedPath.path
        }

        // MLX inference is Metal (GPU) work, and iOS TERMINATES apps that
        // submit GPU work while backgrounded — the background-audio
        // entitlement keeps rehearsal playing in the background, so every
        // freshly-synthesized line there was an instant kill. Refuse (the
        // Dart side falls back to system TTS, which is background-legal)
        // instead of crashing.
        let inBackground = await MainActor.run {
            UIApplication.shared.applicationState == .background
        }
        if inBackground {
            NSLog("KokoroMLX: refusing synthesis while backgrounded (GPU work would be killed)")
            throw KokoroError.backgrounded
        }

        // Mark this generation so older in-flight calls can bail out
        synthGeneration += 1
        let myGeneration = synthGeneration

        // Determine language from voice prefix
        let language: Language = voice.hasPrefix("a") ? .enUS : .enGB

        // Run synthesis on a serial queue to prevent concurrent NLTagger access
        let result: String = try await withCheckedThrowingContinuation { continuation in
            synthQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: KokoroError.modelNotLoaded)
                    return
                }

                // If a newer synthesis was requested, skip this one
                if myGeneration != self.synthGeneration {
                    continuation.resume(throwing: KokoroError.cancelled)
                    return
                }

                // Re-check HERE, not just at call time: this block may have sat
                // behind an in-flight synthesis for seconds, and the app can
                // have been backgrounded meanwhile. Submitting Metal work in
                // the background is an immediate iOS kill.
                if Self.isBackgrounded {
                    NSLog("KokoroMLX: app backgrounded before queued synthesis ran — skipping GPU work")
                    continuation.resume(throwing: KokoroError.backgrounded)
                    return
                }

                do {
                    // Generate audio via Kokoro MLX inference
                    let (audioSamples, _) = try ttsEngine.generateAudio(
                        voice: voiceEmbedding,
                        language: language,
                        text: text,
                        speed: speed
                    )

                    // Force GPU sync to catch Metal errors before they fire
                    // asynchronously and crash the process via check_error()
                    Stream.gpu.synchronize()

                    guard !audioSamples.isEmpty else {
                        continuation.resume(throwing: KokoroError.emptyAudio)
                        return
                    }

                    // Write to a cached WAV file
                    let outputPath = self.cacheURL(for: text, voice: voice, speed: speed)
                    let sampleRate = KokoroTTS.Constants.samplingRate
                    try self.writeWAV(samples: audioSamples, sampleRate: sampleRate, to: outputPath)

                    // Free MLX intermediate computation buffers
                    Memory.clearCache()

                    // Deliberately do NOT touch the AVAudioSession here.
                    // Rehearsal PREFETCHES the next line's audio while the
                    // actor is speaking — flipping the session to .playback at
                    // synthesis-complete killed the live STT mic tap mid-line.
                    // Dart's PlaybackSession.ensurePlayback() sets .playback
                    // at actual play time instead.

                    continuation.resume(returning: outputPath.path)
                } catch {
                    // Clear GPU state on error to prevent cascading Metal failures
                    Memory.clearCache()
                    continuation.resume(throwing: error)
                }
            }
        }

        return result
    }

    // MARK: - Audio encoding

    private func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        // Create directory if needed
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Convert Float32 samples to Int16 PCM. One contiguous buffer + one
        // Data init — the previous per-sample `Data(bytes:&int16,count:2)`
        // append made ~120k heap allocations per 5 s clip on the TTS path.
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, sample) in samples.enumerated() {
            let clamped = max(-1.0, min(1.0, sample))
            pcm[i] = Int16(clamped * Float(Int16.max))
        }
        let pcmData = pcm.withUnsafeBufferPointer { Data(buffer: $0) }

        // Build WAV header + data
        var wav = Data()
        let dataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + pcmData.count)

        wav.append("RIFF".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // chunk size
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // PCM format
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // mono
        wav.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Data($0) }) // byte rate
        wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })  // block align
        wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }) // bits per sample
        wav.append("data".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(pcmData)

        // Atomic: a kill mid-write would otherwise leave a truncated file at a
        // stable cache key — a permanent bad cache hit on every later launch.
        try wav.write(to: url, options: .atomic)
    }

    // MARK: - Caching

    private func cacheURL(for text: String, voice: String, speed: Float) -> URL {
        // SHA-256, NOT String.hashValue: hashValue is seed-randomized per
        // process, so the old keys never matched across launches — the cache
        // was write-only and grew forever.
        let keySource = "\(text)|\(voice)|\(String(format: "%.2f", speed))"
        let digest = SHA256.hash(data: Data(keySource.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kokoro_tts", isDirectory: true)
        return cacheDir.appendingPathComponent("\(hex).wav")
    }

    /// LRU-prune the synthesis cache to ~200MB. Runs once per launch on a
    /// utility queue (kicked from the first synthesize call).
    private static var pruneScheduled = false
    func pruneCacheIfNeeded() {
        guard !Self.pruneScheduled else { return }
        Self.pruneScheduled = true
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("kokoro_tts", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return }
            var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            let maxBytes = 200 * 1024 * 1024
            var total = entries.reduce(0) { $0 + $1.size }
            guard total > maxBytes else { return }
            entries.sort { $0.date < $1.date } // oldest first
            var removed = 0
            for entry in entries {
                if total <= maxBytes { break }
                try? fm.removeItem(at: entry.url)
                total -= entry.size
                removed += 1
            }
            NSLog("KokoroMLX: pruned \(removed) cached WAVs (cache was over 200MB)")
        }
    }

    private var modelDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/kokoro_mlx", isDirectory: true)
    }
}

// MARK: - Errors

enum KokoroError: LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded
    case modelCorrupt(String)
    case voicesNotDownloaded
    case voiceNotFound(String)
    case emptyAudio
    case cancelled
    case backgrounded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Kokoro model not loaded. Call loadModel() first."
        case .modelNotDownloaded: return "Kokoro model file not found. Download kokoro-v1_0.safetensors first."
        case .modelCorrupt(let e): return "Kokoro model file was corrupt and has been removed — re-download it in Settings → AI Models. (\(e))"
        case .voicesNotDownloaded: return "Voice embeddings file not found. Download voices.npz first."
        case .voiceNotFound(let v): return "Voice '\(v)' not found in voice embeddings."
        case .emptyAudio: return "No audio generated for the given text."
        case .cancelled: return "Synthesis cancelled (newer request superseded)."
        case .backgrounded:
            return "App is backgrounded — GPU synthesis unavailable."
        }
    }
}
