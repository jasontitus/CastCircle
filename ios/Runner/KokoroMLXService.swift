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

    private var ttsEngine: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    /// Serial queue for MLX/NLTagger safety. Requests in one group are siblings;
    /// an urgent request invalidates older groups but never another chunk in its
    /// own group.
    private let synthQueue = DispatchQueue(label: "com.castcircle.kokoro-synth")
    private let requestGate = KokoroRequestGate()

    /// Cache metadata and file ownership live on one queue. Returned paths are
    /// hard-linked into a process-owned delivery directory, so pruning a cache
    /// entry cannot invalidate a file already handed to playback.
    private static let cacheQueue = DispatchQueue(label: "com.castcircle.kokoro-cache")
    private static let deliveryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kokoro_tts_deliveries-\(UUID().uuidString)", isDirectory: true)
    private static var cachePrepared = false
    private struct CacheEntry {
        var modificationDate: Date
        let size: Int
    }
    private static var cacheEntries: [URL: CacheEntry] = [:]
    private static var cacheBytes = 0
    private static var activeDeliveries: Set<URL> = []

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

    /// Synthesize speech and return an owned WAV delivery path.
    ///
    /// MLX remains serial, but cancellation is group-aware: sibling chunks in
    /// one request group all run, while an explicit urgent group invalidates
    /// groups that were already known when it arrived.
    func synthesize(
        text: String,
        voice: String,
        speed: Float,
        requestGroup: String,
        urgent: Bool
    ) async throws -> String {
        guard !requestGroup.isEmpty else {
            throw KokoroError.invalidRequestGroup
        }
        guard requestGate.register(group: requestGroup, urgent: urgent) else {
            throw KokoroError.cancelled
        }
        guard let ttsEngine = ttsEngine else {
            throw KokoroError.modelNotLoaded
        }

        let voiceKey = voice + ".npy"
        guard let voiceEmbedding = voices[voiceKey] else {
            throw KokoroError.voiceNotFound(voice)
        }

        let cachedPath = cacheURL(for: text, voice: voice, speed: speed)
        if let delivery = try cachedDeliveryIfPresent(
            at: cachedPath,
            requestGroup: requestGroup
        ) {
            guard requestGate.isActive(requestGroup) else {
                _ = try releaseDelivery(atPath: delivery)
                throw KokoroError.cancelled
            }
            return delivery
        }

        let inBackground = await MainActor.run {
            UIApplication.shared.applicationState == .background
        }
        if inBackground {
            NSLog("KokoroMLX: refusing synthesis while backgrounded (GPU work would be killed)")
            throw KokoroError.backgrounded
        }

        let language: Language = voice.hasPrefix("a") ? .enUS : .enGB
        return try await withCheckedThrowingContinuation { continuation in
            synthQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: KokoroError.modelNotLoaded)
                    return
                }
                guard self.requestGate.isActive(requestGroup) else {
                    continuation.resume(throwing: KokoroError.cancelled)
                    return
                }
                if Self.isBackgrounded {
                    NSLog("KokoroMLX: app backgrounded before queued synthesis ran — skipping GPU work")
                    continuation.resume(throwing: KokoroError.backgrounded)
                    return
                }

                do {
                    let (audioSamples, _) = try ttsEngine.generateAudio(
                        voice: voiceEmbedding,
                        language: language,
                        text: text,
                        speed: speed
                    )
                    Stream.gpu.synchronize()
                    guard !audioSamples.isEmpty else {
                        throw KokoroError.emptyAudio
                    }

                    let sampleRate = KokoroTTS.Constants.samplingRate
                    guard self.requestGate.isActive(requestGroup) else {
                        throw KokoroError.cancelled
                    }
                    let delivery = try self.storeAndDeliver(
                        samples: audioSamples,
                        sampleRate: sampleRate,
                        at: cachedPath,
                        requestGroup: requestGroup
                    )
                    Memory.clearCache()
                    guard self.requestGate.isActive(requestGroup) else {
                        _ = try self.releaseDelivery(atPath: delivery)
                        throw KokoroError.cancelled
                    }
                    continuation.resume(returning: delivery)
                } catch {
                    Memory.clearCache()
                    continuation.resume(throwing: error)
                }
            }
        }
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

    private func cachedDeliveryIfPresent(
        at cacheURL: URL,
        requestGroup: String
    ) throws -> String? {
        try Self.cacheQueue.sync {
            try Self.prepareCacheLocked()
            guard FileManager.default.fileExists(atPath: cacheURL.path) else {
                if let missing = Self.cacheEntries.removeValue(forKey: cacheURL) {
                    Self.cacheBytes -= missing.size
                }
                Self.pruneCacheLocked()
                return nil
            }

            let now = Date()
            try FileManager.default.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: cacheURL.path
            )
            if let prior = Self.cacheEntries[cacheURL] {
                Self.cacheEntries[cacheURL] = CacheEntry(
                    modificationDate: now,
                    size: prior.size
                )
            }
            guard requestGate.isActive(requestGroup) else {
                Self.pruneCacheLocked()
                throw KokoroError.cancelled
            }
            let delivery = try Self.makeDeliveryLocked(from: cacheURL)
            Self.pruneCacheLocked()
            return delivery.path
        }
    }

    private func storeAndDeliver(
        samples: [Float],
        sampleRate: Int,
        at cacheURL: URL,
        requestGroup: String
    ) throws -> String {
        try Self.cacheQueue.sync {
            try Self.prepareCacheLocked()
            if let prior = Self.cacheEntries.removeValue(forKey: cacheURL) {
                Self.cacheBytes -= prior.size
            }
            try writeWAV(samples: samples, sampleRate: sampleRate, to: cacheURL)
            let values = try cacheURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            guard let size = values.fileSize else {
                throw KokoroError.cacheFailure("Could not determine the size of the new WAV")
            }
            Self.cacheEntries[cacheURL] = CacheEntry(
                modificationDate: values.contentModificationDate ?? Date(),
                size: size
            )
            Self.cacheBytes += size
            guard requestGate.isActive(requestGroup) else {
                Self.pruneCacheLocked()
                throw KokoroError.cancelled
            }
            let delivery = try Self.makeDeliveryLocked(from: cacheURL)
            Self.pruneCacheLocked()
            return delivery.path
        }
    }

    private static func prepareCacheLocked() throws {
        guard !cachePrepared else { return }
        let fm = FileManager.default
        let cacheDirectory = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kokoro_tts", isDirectory: true)
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let tempRoot = fm.temporaryDirectory
        do {
            let staleDeliveries = try fm.contentsOfDirectory(
                at: tempRoot,
                includingPropertiesForKeys: nil
            )
            for stale in staleDeliveries
                where stale.lastPathComponent.hasPrefix("kokoro_tts_deliveries-")
                    && stale != deliveryDirectory {
                do {
                    try fm.removeItem(at: stale)
                } catch {
                    NSLog("KokoroMLX: could not remove stale delivery directory: \(error)")
                }
            }
        } catch {
            NSLog("KokoroMLX: could not enumerate stale delivery directories: \(error)")
        }
        try fm.createDirectory(at: deliveryDirectory, withIntermediateDirectories: true)

        let files = try fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        cacheEntries.removeAll(keepingCapacity: true)
        cacheBytes = 0
        for file in files where file.pathExtension == "wav" {
            let values = try file.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            guard let size = values.fileSize else {
                throw KokoroError.cacheFailure("Could not account for \(file.lastPathComponent)")
            }
            cacheEntries[file] = CacheEntry(
                modificationDate: values.contentModificationDate ?? .distantPast,
                size: size
            )
            cacheBytes += size
        }
        cachePrepared = true
    }

    private static func makeDeliveryLocked(from cacheURL: URL) throws -> URL {
        let deliveryURL = deliveryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        do {
            try FileManager.default.linkItem(at: cacheURL, to: deliveryURL)
        } catch {
            NSLog("KokoroMLX: hard-link delivery unavailable; copying WAV: \(error)")
            try FileManager.default.copyItem(at: cacheURL, to: deliveryURL)
        }
        activeDeliveries.insert(deliveryURL)
        return deliveryURL
    }

    @discardableResult
    func releaseDelivery(atPath path: String) throws -> Bool {
        let deliveryURL = URL(fileURLWithPath: path).standardizedFileURL
        return try Self.cacheQueue.sync {
            let root = Self.deliveryDirectory.standardizedFileURL
            guard deliveryURL.deletingLastPathComponent() == root,
                  Self.activeDeliveries.remove(deliveryURL) != nil else {
                return false
            }
            do {
                try FileManager.default.removeItem(at: deliveryURL)
            } catch {
                if (error as? CocoaError)?.code != .fileNoSuchFile {
                    Self.activeDeliveries.insert(deliveryURL)
                    throw KokoroError.cacheFailure(
                        "Could not release \(deliveryURL.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
            return true
        }
    }

    private static func pruneCacheLocked() {
        let maxBytes = 200 * 1024 * 1024
        let lowWater = 150 * 1024 * 1024
        guard cacheBytes > maxBytes else { return }

        let oldestFirst = cacheEntries.sorted {
            $0.value.modificationDate < $1.value.modificationDate
        }
        var removed = 0
        for (url, entry) in oldestFirst {
            if cacheBytes <= lowWater { break }
            do {
                try FileManager.default.removeItem(at: url)
                cacheEntries.removeValue(forKey: url)
                cacheBytes -= entry.size
                removed += 1
            } catch {
                if (error as? CocoaError)?.code == .fileNoSuchFile {
                    // iOS may purge Caches behind us; the bytes are already
                    // gone, so reconcile the inventory rather than retaining
                    // a phantom entry.
                    cacheEntries.removeValue(forKey: url)
                    cacheBytes -= entry.size
                } else {
                    // Real failed deletes remain in both inventory and total.
                    NSLog("KokoroMLX: failed to prune \(url.lastPathComponent): \(error)")
                }
            }
        }
        NSLog("KokoroMLX: pruned \(removed) cached WAVs; accounted cache is \(cacheBytes) bytes")
    }

    private var modelDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/kokoro_mlx", isDirectory: true)
    }
}

// MARK: - Errors

/// Thread-safe cancellation policy shared by the channel's concurrent Tasks.
/// Group IDs are unique for one logical prefetch/speak operation.
final class KokoroRequestGate {
    private let lock = NSLock()
    private var knownGroups: Set<String> = []
    private var invalidatedGroups: Set<String> = []
    private var urgentGroups: Set<String> = []

    func register(group: String, urgent: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if urgent && urgentGroups.insert(group).inserted {
            for existing in knownGroups where existing != group {
                invalidatedGroups.insert(existing)
            }
            invalidatedGroups.remove(group)
        }
        knownGroups.insert(group)
        return !invalidatedGroups.contains(group)
    }

    func isActive(_ group: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !invalidatedGroups.contains(group)
    }
}

enum KokoroError: LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded
    case modelCorrupt(String)
    case voicesNotDownloaded
    case voiceNotFound(String)
    case emptyAudio
    case cancelled
    case backgrounded
    case invalidRequestGroup
    case cacheFailure(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Kokoro model not loaded. Call loadModel() first."
        case .modelNotDownloaded: return "Kokoro model file not found. Download kokoro-v1_0.safetensors first."
        case .modelCorrupt(let e): return "Kokoro model file was corrupt and has been removed — re-download it in Settings → AI Models. (\(e))"
        case .voicesNotDownloaded: return "Voice embeddings file not found. Download voices.npz first."
        case .voiceNotFound(let v): return "Voice '\(v)' not found in voice embeddings."
        case .emptyAudio: return "No audio generated for the given text."
        case .cancelled: return "Synthesis cancelled (newer request superseded)."
        case .invalidRequestGroup: return "Synthesis requestGroup must be nonempty."
        case .cacheFailure(let message): return "Kokoro cache failed: \(message)"
        case .backgrounded:
            return "App is backgrounded — GPU synthesis unavailable."
        }
    }
}
