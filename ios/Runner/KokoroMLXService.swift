import Foundation
import Accelerate
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

    /// All model lifecycle operations and inference run on this queue. Keeping
    /// construction, publication, use, and teardown on one executor prevents
    /// partially-published state and keeps MLX/NLTagger access serialized.
    private let modelQueue = DispatchQueue(label: "com.castcircle.kokoro-model")
    private var ttsEngine: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    /// Incremented on each synthesize call; older queued calls bail out early.
    private var synthGeneration: Int = 0
    private let genLock = NSLock()

    private static let expectedModelSHA256 =
        "733bc3015578aad992f87863f8e6f90dbe00040bd3207d925b9ed693fa09e7bb"
    private static let expectedVoicesSHA256 =
        "56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f"

    func isModelLoaded() async -> Bool {
        await withCheckedContinuation { continuation in
            modelQueue.async {
                continuation.resume(returning: self.ttsEngine != nil && !self.voices.isEmpty)
            }
        }
    }

    func modelStatus() async -> (loaded: Bool, downloaded: Bool) {
        await withCheckedContinuation { continuation in
            modelQueue.async {
                let loaded = self.ttsEngine != nil && !self.voices.isEmpty
                let modelURL = self.modelDirectory.appendingPathComponent("kokoro-v1_0.safetensors")
                let voicesURL = self.modelDirectory.appendingPathComponent("voices.npz")
                let downloaded = FileManager.default.fileExists(atPath: modelURL.path)
                    && FileManager.default.fileExists(atPath: voicesURL.path)
                continuation.resume(returning: (loaded, downloaded))
            }
        }
    }

    // MARK: - Background state

    /// `modelQueue` callers re-check this snapshot before submitting GPU work.
    /// `applicationState` is main-thread-only, so it cannot be read there.
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
        try await withCheckedThrowingContinuation { continuation in
            modelQueue.async {
                do {
                    try self.loadModelOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadModelOnQueue() throws {
        if ttsEngine != nil { return }

        let modelURL = modelDirectory.appendingPathComponent("kokoro-v1_0.safetensors")
        let voicesURL = modelDirectory.appendingPathComponent("voices.npz")

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw KokoroError.modelNotDownloaded
        }
        guard FileManager.default.fileExists(atPath: voicesURL.path) else {
            throw KokoroError.voicesNotDownloaded
        }

        // The model pack is immutable and pinned by the downloader. Verify the
        // complete artifact before any vendored constructors can reach their
        // force-unwrapped weight lookups. This is stronger than checking only
        // a subset of required tensor names/shapes: every metadata and tensor
        // byte must match the known-compatible pack.
        guard try hasExpectedSHA256(modelURL, expected: Self.expectedModelSHA256) else {
            try? FileManager.default.removeItem(at: modelURL)
            throw KokoroError.modelCorrupt("SHA-256 did not match the supported model pack")
        }
        guard try hasExpectedSHA256(voicesURL, expected: Self.expectedVoicesSHA256) else {
            try? FileManager.default.removeItem(at: voicesURL)
            throw KokoroError.voicesCorrupt("SHA-256 did not match the supported voices pack")
        }

        let loadedEngine: KokoroTTS
        do {
            loadedEngine = try KokoroTTS(modelPath: modelURL)
        } catch {
            // A digest-verified model is not corrupt. Preserve it across
            // transient I/O/resource failures rather than forcing a 164 MB
            // re-download.
            throw KokoroError.modelLoadFailed(String(describing: error))
        }

        guard let loadedVoices = NpyzReader.read(fileFromPath: voicesURL),
              !loadedVoices.isEmpty else {
            throw KokoroError.voicesLoadFailed
        }
        guard Self.voicesAreCompatible(loadedVoices) else {
            try? FileManager.default.removeItem(at: voicesURL)
            throw KokoroError.voicesCorrupt("Unexpected voice tensor names or shapes")
        }

        // Publish both halves together only after the entire pack validates.
        ttsEngine = loadedEngine
        voices = loadedVoices

        // NOTE: deliberately no AVAudioSession configuration here. The shared
        // session is owned by whoever is actively capturing/playing; the Dart
        // side (PlaybackSession.ensurePlayback) sets .playback right before
        // audio is played. Flipping it here breaks a live STT session.
    }

    private func hasExpectedSHA256(_ url: URL, expected: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == expected
    }

    private static func voicesAreCompatible(_ voices: [String: MLXArray]) -> Bool {
        let expectedShape = [KokoroTTS.Constants.maxTokenCount, 1, 256]
        guard voices.values.allSatisfy({ $0.shape == expectedShape }) else {
            return false
        }
        return availableVoices.allSatisfy { voices[$0 + ".npy"] != nil }
    }

    /// Unload the model from memory without deleting files.
    /// Call this when TTS is not needed to reduce memory pressure.
    func unloadModel() async {
        await withCheckedContinuation { continuation in
            modelQueue.async {
                self.ttsEngine = nil
                self.voices = [:]
                Memory.clearCache()
                NSLog("KokoroMLX: Model unloaded, MLX cache cleared")
                continuation.resume()
            }
        }
    }

    /// Delete downloaded model weights to free storage.
    func deleteModel() async throws {
        try await withCheckedThrowingContinuation { continuation in
            modelQueue.async {
                do {
                    self.ttsEngine = nil
                    self.voices = [:]
                    Memory.clearCache()
                    let dir = self.modelDirectory
                    if FileManager.default.fileExists(atPath: dir.path) {
                        try FileManager.default.removeItem(at: dir)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Synthesis

    /// Synthesize speech and return the path to a WAV file.
    /// Serialized with model lifecycle operations to prevent concurrent
    /// NLTagger/MLX access and teardown during inference.
    func synthesize(text: String, voice: String, speed: Float) async throws -> String {

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
        genLock.lock()
        synthGeneration += 1
        let myGeneration = synthGeneration
        genLock.unlock()

        // Determine language from voice prefix
        let language: Language = voice.hasPrefix("a") ? .enUS : .enGB

        // Run synthesis on the same serial queue as load/unload/delete.
        let result: String = try await withCheckedThrowingContinuation { continuation in
            modelQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: KokoroError.modelNotLoaded)
                    return
                }

                guard let ttsEngine = self.ttsEngine else {
                    continuation.resume(throwing: KokoroError.modelNotLoaded)
                    return
                }

                // Look up voice embedding — voice names in the NPZ have ".npy" suffix.
                let voiceKey = voice + ".npy"
                guard let voiceEmbedding = self.voices[voiceKey] else {
                    continuation.resume(throwing: KokoroError.voiceNotFound(voice))
                    return
                }

                let cachedPath = self.cacheURL(for: text, voice: voice, speed: speed)
                Self.cacheLock.lock()
                let cacheHit = FileManager.default.fileExists(atPath: cachedPath.path)
                if cacheHit {
                    do {
                        try FileManager.default.setAttributes(
                            [.modificationDate: Date()], ofItemAtPath: cachedPath.path)
                    } catch {
                        Self.cacheLock.unlock()
                        continuation.resume(throwing: error)
                        return
                    }
                }
                Self.cacheLock.unlock()
                if cacheHit {
                    self.pruneCacheIfNeeded()
                    continuation.resume(returning: cachedPath.path)
                    return
                }

                // If a newer synthesis was requested, skip this one
                self.genLock.lock()
                let currentGeneration = self.synthGeneration
                self.genLock.unlock()
                if myGeneration != currentGeneration {
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
                    self.pruneCacheIfNeeded()

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
        var lo: Float = -1.0
        var hi: Float = 1.0
        var scale = Float(Int16.max)
        var scaled = [Float](repeating: 0, count: samples.count)
        vDSP_vclip(samples, 1, &lo, &hi, &scaled, 1, vDSP_Length(samples.count))
        vDSP_vsmul(scaled, 1, &scale, &scaled, 1, vDSP_Length(samples.count))
        vDSP_vfix16(scaled, 1, &pcm, 1, vDSP_Length(samples.count))
        let pcmData = pcm.withUnsafeBufferPointer { Data(buffer: $0) }

        // Build WAV header + data
        var wav = Data()
        wav.reserveCapacity(44 + pcmData.count)
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

    /// LRU-prune the synthesis cache to ~200MB. The guard is re-armed after
    /// each pass so later synthesis can enforce the cap as the cache grows.
    /// The lock also pins cache hits while their LRU timestamp is refreshed.
    private static let cacheLock = NSLock()
    private static var pruneScheduled = false

    func pruneCacheIfNeeded() {
        Self.cacheLock.lock()
        guard !Self.pruneScheduled else {
            Self.cacheLock.unlock()
            return
        }
        Self.pruneScheduled = true
        Self.cacheLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("kokoro_tts", isDirectory: true)

            Self.cacheLock.lock()
            defer {
                Self.pruneScheduled = false
                Self.cacheLock.unlock()
            }

            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return }
            var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            let maxBytes = 200 * 1024 * 1024
            let lowWater = 150 * 1024 * 1024
            var total = entries.reduce(0) { $0 + $1.size }
            guard total > maxBytes else { return }
            entries.sort { $0.date < $1.date }
            var removed = 0
            for entry in entries {
                if total <= lowWater { break }
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
    case modelLoadFailed(String)
    case voicesNotDownloaded
    case voicesCorrupt(String)
    case voicesLoadFailed
    case voiceNotFound(String)
    case emptyAudio
    case cancelled
    case backgrounded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Kokoro model not loaded. Call loadModel() first."
        case .modelNotDownloaded: return "Kokoro model file not found. Download kokoro-v1_0.safetensors first."
        case .modelCorrupt(let e): return "Kokoro model file was corrupt and has been removed — re-download it in Settings → AI Models. (\(e))"
        case .modelLoadFailed(let e): return "Kokoro model could not be loaded. The verified download was retained. (\(e))"
        case .voicesNotDownloaded: return "Voice embeddings file not found. Download voices.npz first."
        case .voicesCorrupt(let e): return "Voice embeddings were corrupt and have been removed — re-download them in Settings → AI Models. (\(e))"
        case .voicesLoadFailed: return "Voice embeddings could not be loaded. The verified download was retained."
        case .voiceNotFound(let v): return "Voice '\(v)' not found in voice embeddings."
        case .emptyAudio: return "No audio generated for the given text."
        case .cancelled: return "Synthesis cancelled (newer request superseded)."
        case .backgrounded:
            return "App is backgrounded — GPU synthesis unavailable."
        }
    }
}
