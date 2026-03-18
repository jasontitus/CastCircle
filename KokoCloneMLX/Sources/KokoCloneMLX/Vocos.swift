import Foundation
import MLX

/// Vocos mel-24kHz vocoder (13.5M params).
///
/// Converts mel spectrogram (B, 100, T) → waveform (B, T*256) at 24kHz.
/// Architecture: ConvNeXt backbone (8 layers) → ISTFT head.
public class VocosModel {

    // Backbone: Conv1d embed + 8 ConvNeXt blocks + LayerNorm
    let embedWeight: MLXArray   // Conv1d(100, 512, 7, pad=3) — MLX: (512, 7, 100)
    let embedBias: MLXArray
    let normWeight: MLXArray
    let normBias: MLXArray
    let blocks: [ConvNeXtBlock]
    let finalNormWeight: MLXArray
    let finalNormBias: MLXArray

    // ISTFT head: Linear(512, 1026)
    let headWeight: MLXArray
    let headBias: MLXArray

    // ISTFT parameters
    let nFFT: Int = 1024
    let hopLength: Int = 256
    let hannWindow: [Float]

    public init(weights: [String: MLXArray]) {
        self.embedWeight = weights["backbone.embed.weight"]!
        self.embedBias = weights["backbone.embed.bias"]!
        self.normWeight = weights["backbone.norm.weight"]!
        self.normBias = weights["backbone.norm.bias"]!

        var blockList: [ConvNeXtBlock] = []
        for i in 0..<8 {
            blockList.append(ConvNeXtBlock(
                weights: weights,
                prefix: "backbone.convnext.\(i)",
                channels: 512
            ))
        }
        self.blocks = blockList

        self.finalNormWeight = weights["backbone.final_layer_norm.weight"]!
        self.finalNormBias = weights["backbone.final_layer_norm.bias"]!

        self.headWeight = weights["head.out.weight"]!
        self.headBias = weights["head.out.bias"]!

        // Precompute Hann window
        var window = [Float](repeating: 0, count: 1024)
        for i in 0..<1024 {
            window[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / 1024.0))
        }
        self.hannWindow = window
    }

    /// Decode mel spectrogram to waveform.
    /// mel: (B, 100, T) — log mel spectrogram
    /// Returns: (B, T * hopLength) waveform at 24kHz
    public func decode(mel: MLXArray) -> MLXArray {
        // Backbone: ConvNeXt
        // Embed: Conv1d(100, 512, 7, pad=3)
        let melT = mel.transposed(0, 2, 1)  // (B, T, 100)
        var x = MLX.conv1d(melT, embedWeight, stride: 1, padding: 3)  // (B, T, 512)
        x = x + embedBias

        // LayerNorm
        x = layerNorm(x, weight: normWeight, bias: normBias, eps: 1e-6)

        // Transpose for ConvNeXt: (B, T, 512) -> (B, 512, T)
        x = x.transposed(0, 2, 1)

        // 8 ConvNeXt blocks
        for block in blocks {
            x = block(x)
        }

        // Final norm: (B, 512, T) -> (B, T, 512)
        x = x.transposed(0, 2, 1)
        x = layerNorm(x, weight: finalNormWeight, bias: finalNormBias, eps: 1e-6)

        // ISTFT head: Linear(512, 1026) → split into magnitude (513) + phase (513)
        x = MLX.matmul(x, headWeight.transposed()) + headBias  // (B, T, 1026)

        // Split into magnitude and phase
        let nFreqs = nFFT / 2 + 1  // 513
        let magLog = x[0..., 0..., 0..<nFreqs]
        let phase = x[0..., 0..., nFreqs...]

        // Magnitude: exp(x), clamped
        let mag = MLX.minimum(MLX.exp(magLog), MLXArray(Float(100.0)))

        // Complex spectrogram: mag * (cos(phase) + j*sin(phase))
        let real = mag * MLX.cos(phase)
        let imag = mag * MLX.sin(phase)

        // ISTFT
        return istft(real: real, imag: imag)
    }

    /// Inverse Short-Time Fourier Transform.
    /// real, imag: (B, T_frames, n_freqs) where n_freqs = nFFT/2 + 1
    /// Returns: (B, T_samples)
    private func istft(real: MLXArray, imag: MLXArray) -> MLXArray {
        // Pull to CPU arrays for the ISTFT overlap-add
        let B = real.shape[0]
        let numFrames = real.shape[1]
        let nFreqs = nFFT / 2 + 1

        let realFlat: [Float] = real.reshaped([-1]).asArray(Float.self)
        let imagFlat: [Float] = imag.reshaped([-1]).asArray(Float.self)

        let outputLength = (numFrames - 1) * hopLength + nFFT
        // Center padding: trim nFFT/2 from each side
        let trimStart = nFFT / 2
        let trimEnd = outputLength - nFFT / 2
        let finalLength = trimEnd - trimStart

        var allOutputs = [Float](repeating: 0, count: B * finalLength)

        for b in 0..<B {
            var output = [Float](repeating: 0, count: outputLength)
            var windowSum = [Float](repeating: 0, count: outputLength)

            for frame in 0..<numFrames {
                let offset = b * numFrames * nFreqs + frame * nFreqs

                // Build full spectrum (nFFT complex values) from half-spectrum
                var specReal = [Float](repeating: 0, count: nFFT)
                var specImag = [Float](repeating: 0, count: nFFT)

                for k in 0..<nFreqs {
                    specReal[k] = realFlat[offset + k]
                    specImag[k] = imagFlat[offset + k]
                }
                // Mirror for negative frequencies (conjugate symmetry)
                for k in 1..<(nFFT / 2) {
                    specReal[nFFT - k] = specReal[k]
                    specImag[nFFT - k] = -specImag[k]
                }

                // IFFT (DFT-based, nFFT points)
                let frameSamples = ifft(real: specReal, imag: specImag, n: nFFT)

                // Window and overlap-add
                let start = frame * hopLength
                for i in 0..<nFFT {
                    output[start + i] += frameSamples[i] * hannWindow[i]
                    windowSum[start + i] += hannWindow[i] * hannWindow[i]
                }
            }

            // Normalize by window sum (NOLA condition)
            for i in 0..<outputLength {
                if windowSum[i] > 1e-8 {
                    output[i] /= windowSum[i]
                }
            }

            // Trim center padding
            for i in 0..<finalLength {
                allOutputs[b * finalLength + i] = output[trimStart + i]
            }
        }

        return MLXArray(allOutputs).reshaped([B, finalLength])
    }

    /// Simple DFT-based IFFT for a single frame.
    private func ifft(real: [Float], imag: [Float], n: Int) -> [Float] {
        var output = [Float](repeating: 0, count: n)
        let invN = 1.0 / Float(n)

        for t in 0..<n {
            var sum: Float = 0
            for k in 0..<n {
                let angle = 2.0 * Float.pi * Float(t) * Float(k) * invN
                sum += real[k] * cos(angle) - imag[k] * sin(angle)
            }
            output[t] = sum * invN
        }
        return output
    }
}
