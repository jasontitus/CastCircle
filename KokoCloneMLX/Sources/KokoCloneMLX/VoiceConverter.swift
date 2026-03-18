import Foundation
import MLX

/// Top-level KokoClone voice converter.
///
/// Pipeline:
///   1. Kokoro TTS generates speech with a default voice (external)
///   2. WavLM extracts SSL features from source and reference audio
///   3. Kanade encodes content tokens from source, speaker embedding from reference
///   4. Kanade decodes mel spectrogram with source content + reference speaker
///   5. Vocos converts mel to waveform
public class VoiceConverter {

    private var wavlm: WavLMBaseP?
    private var kanade: KanadeModel?
    private var vocos: VocosModel?
    private var melFilterbank: MLXArray?

    public var isLoaded: Bool {
        wavlm != nil && kanade != nil && vocos != nil && melFilterbank != nil
    }

    public init() {}

    // MARK: - Model Loading

    /// Load all models from a directory containing:
    ///   - wavlm_base_plus.safetensors
    ///   - kanade_25hz.safetensors
    ///   - vocos_mel_24khz.safetensors
    ///   - mel_filterbank.safetensors
    public func loadModels(from directory: URL) throws {
        let start = CFAbsoluteTimeGetCurrent()

        // Load WavLM
        let wavlmURL = directory.appendingPathComponent("wavlm_base_plus.safetensors")
        guard FileManager.default.fileExists(atPath: wavlmURL.path) else {
            throw KokoCloneError.modelNotLoaded("wavlm_base_plus.safetensors not found")
        }
        print("Loading WavLM-Base+...")
        let wavlmWeights = try loadSafetensors(url: wavlmURL)
        wavlm = WavLMBaseP(weights: wavlmWeights)

        // Load Kanade
        let kanadeURL = directory.appendingPathComponent("kanade_25hz.safetensors")
        guard FileManager.default.fileExists(atPath: kanadeURL.path) else {
            throw KokoCloneError.modelNotLoaded("kanade_25hz.safetensors not found")
        }
        print("Loading Kanade-25Hz...")
        let kanadeWeights = try loadSafetensors(url: kanadeURL)
        kanade = KanadeModel(weights: kanadeWeights)

        // Load Vocos
        let vocosURL = directory.appendingPathComponent("vocos_mel_24khz.safetensors")
        guard FileManager.default.fileExists(atPath: vocosURL.path) else {
            throw KokoCloneError.modelNotLoaded("vocos_mel_24khz.safetensors not found")
        }
        print("Loading Vocos mel-24kHz...")
        let vocosWeights = try loadSafetensors(url: vocosURL)
        vocos = VocosModel(weights: vocosWeights)

        // Load mel filterbank
        let melFBURL = directory.appendingPathComponent("mel_filterbank.safetensors")
        guard FileManager.default.fileExists(atPath: melFBURL.path) else {
            throw KokoCloneError.modelNotLoaded("mel_filterbank.safetensors not found")
        }
        let melFBWeights = try loadSafetensors(url: melFBURL)
        melFilterbank = melFBWeights["mel_filterbank"]!

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("All models loaded in \(String(format: "%.1f", elapsed))s")
    }

    /// Unload all models to free memory.
    public func unloadModels() {
        wavlm = nil
        kanade = nil
        vocos = nil
        melFilterbank = nil
        GPU.clearCache()
    }

    // MARK: - Voice Conversion

    /// Convert the voice of source audio to sound like the reference speaker.
    ///
    /// - Parameters:
    ///   - sourceAudio: Source audio samples at 24kHz (from Kokoro TTS output)
    ///   - referenceAudio: Reference audio samples at 24kHz (from cast recording)
    /// - Returns: Converted audio samples at 24kHz
    public func convertVoice(
        sourceAudio: MLXArray,
        referenceAudio: MLXArray
    ) throws -> MLXArray {
        guard let wavlm = wavlm, let kanade = kanade, let vocos = vocos, let melFB = melFilterbank else {
            throw KokoCloneError.modelNotLoaded("Models not loaded. Call loadModels() first.")
        }

        let start = CFAbsoluteTimeGetCurrent()

        // 1. Resample from 24kHz to 16kHz for WavLM
        print("  Resampling to 16kHz...")
        let source16k = resample(sourceAudio, fromRate: 24000, toRate: 16000)
        let ref16k = resample(referenceAudio, fromRate: 24000, toRate: 16000)

        // 2. Extract SSL features from both
        print("  Extracting WavLM features (source)...")
        let sourceSSL = wavlm.extractFeatures(audio: source16k)

        print("  Extracting WavLM features (reference)...")
        let refSSL = wavlm.extractFeatures(audio: ref16k)

        // 3. Compute local SSL features (avg of layers 6, 9 → 0-indexed: 5, 8)
        let sourceLocal = (sourceSSL[5] + sourceSSL[8]) * MLXArray(Float(0.5))

        // 4. Compute global SSL features (avg of layers 1, 2 → 0-indexed: 0, 1)
        let refGlobal = (refSSL[0] + refSSL[1]) * MLXArray(Float(0.5))

        // 5. Encode content from source
        print("  Encoding content tokens...")
        let (contentEmbedding, _) = kanade.encodeContent(localSSLFeatures: sourceLocal)

        // 6. Encode speaker embedding from reference
        print("  Encoding speaker embedding...")
        let speakerEmbedding = kanade.encodeGlobal(globalSSLFeatures: refGlobal)

        // 7. Compute target mel length
        let sourceLength = sourceAudio.shape[sourceAudio.ndim - 1]
        let melLength = sourceLength / 256 + 1

        // 8. Decode mel spectrogram
        print("  Decoding mel spectrogram...")
        let mel = kanade.decode(
            contentEmbedding: contentEmbedding,
            globalEmbedding: speakerEmbedding,
            melLength: melLength
        )

        // 9. Vocode mel → waveform
        print("  Vocoding...")
        let waveform = vocos.decode(mel: mel)

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let rtf = elapsed / (Float(sourceLength) / 24000.0)
        print("  Voice conversion complete: \(String(format: "%.2f", elapsed))s (RTF: \(String(format: "%.2f", rtf)))")

        GPU.clearCache()

        return waveform.squeezed(axis: 0)  // (T,)
    }

    /// Extract and cache a speaker embedding from reference audio.
    /// Use this to avoid re-computing the embedding for every line.
    public func extractSpeakerEmbedding(referenceAudio: MLXArray) throws -> MLXArray {
        guard let wavlm = wavlm, let kanade = kanade else {
            throw KokoCloneError.modelNotLoaded("Models not loaded")
        }

        let ref16k = resample(referenceAudio, fromRate: 24000, toRate: 16000)
        let refSSL = wavlm.extractFeatures(audio: ref16k)
        let refGlobal = (refSSL[0] + refSSL[1]) * MLXArray(Float(0.5))
        return kanade.encodeGlobal(globalSSLFeatures: refGlobal)
    }

    /// Convert voice using a pre-computed speaker embedding.
    public func convertVoiceWithEmbedding(
        sourceAudio: MLXArray,
        speakerEmbedding: MLXArray
    ) throws -> MLXArray {
        guard let wavlm = wavlm, let kanade = kanade, let vocos = vocos else {
            throw KokoCloneError.modelNotLoaded("Models not loaded")
        }

        let source16k = resample(sourceAudio, fromRate: 24000, toRate: 16000)
        let sourceSSL = wavlm.extractFeatures(audio: source16k)
        let sourceLocal = (sourceSSL[5] + sourceSSL[8]) * MLXArray(Float(0.5))

        let (contentEmbedding, _) = kanade.encodeContent(localSSLFeatures: sourceLocal)

        let sourceLength = sourceAudio.shape[sourceAudio.ndim - 1]
        let melLength = sourceLength / 256 + 1

        let mel = kanade.decode(
            contentEmbedding: contentEmbedding,
            globalEmbedding: speakerEmbedding,
            melLength: melLength
        )

        let waveform = vocos.decode(mel: mel)
        GPU.clearCache()

        return waveform.squeezed(axis: 0)
    }

    // MARK: - Safetensors Loading

    private func loadSafetensors(url: URL) throws -> [String: MLXArray] {
        // MLX Swift's built-in safetensors loader
        let weights = try loadArrays(url: url)
        return weights
    }
}
