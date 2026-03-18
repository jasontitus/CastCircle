import Foundation
import AVFoundation
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

    var isModelLoaded: Bool { ttsEngine != nil && !voices.isEmpty }

    var isModelDownloaded: Bool {
        let modelURL = modelDirectory.appendingPathComponent("kokoro-v1_0.safetensors")
        let voicesURL = modelDirectory.appendingPathComponent("voices.npz")
        return FileManager.default.fileExists(atPath: modelURL.path)
            && FileManager.default.fileExists(atPath: voicesURL.path)
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

        // Load TTS engine
        ttsEngine = KokoroTTS(modelPath: modelURL)

        // Load voice embeddings from NPZ file
        voices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
        if voices.isEmpty {
            ttsEngine = nil
            throw KokoroError.voicesNotDownloaded
        }

        // Configure audio session for iOS
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)
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
    func synthesize(text: String, voice: String, speed: Float) async throws -> String {
        guard let ttsEngine = ttsEngine else {
            throw KokoroError.modelNotLoaded
        }

        // Look up voice embedding — voice names in the NPZ have ".npy" suffix
        let voiceKey = voice + ".npy"
        guard let voiceEmbedding = voices[voiceKey] else {
            throw KokoroError.voiceNotFound(voice)
        }

        // Determine language from voice prefix
        let language: Language = voice.hasPrefix("a") ? .enUS : .enGB

        // Generate audio via Kokoro MLX inference
        let (audioSamples, _) = try ttsEngine.generateAudio(
            voice: voiceEmbedding,
            language: language,
            text: text,
            speed: speed
        )

        guard !audioSamples.isEmpty else {
            throw KokoroError.emptyAudio
        }

        // Write to a cached WAV file
        let outputPath = cacheURL(for: text, voice: voice, speed: speed)
        let sampleRate = KokoroTTS.Constants.samplingRate
        try writeWAV(samples: audioSamples, sampleRate: sampleRate, to: outputPath)

        // Free MLX intermediate computation buffers after each synthesis
        // to prevent memory accumulation from attention/hidden state tensors
        Memory.clearCache()

        // Reconfigure audio session for playback before returning.
        // STT sets it to .record — without this, just_audio can't produce sound.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)

        return outputPath.path
    }

    // MARK: - Audio encoding

    private func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        // Create directory if needed
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Convert Float32 samples to Int16 PCM
        let pcmData = samples.withUnsafeBufferPointer { buffer -> Data in
            var data = Data()
            data.reserveCapacity(buffer.count * 2)
            for sample in buffer {
                let clamped = max(-1.0, min(1.0, sample))
                var int16 = Int16(clamped * Float(Int16.max))
                data.append(Data(bytes: &int16, count: 2))
            }
            return data
        }

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

        try wav.write(to: url)
    }

    // MARK: - Caching

    private func cacheURL(for text: String, voice: String, speed: Float) -> URL {
        let hash = "\(text.hashValue)_\(voice)_\(String(format: "%.1f", speed))"
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kokoro_tts", isDirectory: true)
        return cacheDir.appendingPathComponent("\(hash).wav")
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
    case voicesNotDownloaded
    case voiceNotFound(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Kokoro model not loaded. Call loadModel() first."
        case .modelNotDownloaded: return "Kokoro model file not found. Download kokoro-v1_0.safetensors first."
        case .voicesNotDownloaded: return "Voice embeddings file not found. Download voices.npz first."
        case .voiceNotFound(let v): return "Voice '\(v)' not found in voice embeddings."
        case .emptyAudio: return "No audio generated for the given text."
        }
    }
}
