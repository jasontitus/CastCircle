import Foundation
import MLX
import MLXNN

/// Kanade-25Hz voice conversion model.
///
/// Pipeline: SSL features → local encoder → content tokens
///           SSL features → global encoder → speaker embedding
///           content + speaker → mel decoder → mel spectrogram
public class KanadeModel {

    // Config for 25Hz model
    let dim: Int = 768
    let melDim: Int = 512
    let nMels: Int = 100
    let nHeads: Int = 12
    let melDecoderHeads: Int = 8
    let headDim: Int = 64
    let globalDim: Int = 128
    let downsampleFactor: Int = 2
    let melUpsampleFactor: Int = 4
    let fsgLevels: [Int] = [8, 8, 8, 5, 5]

    // RoPE tables (precomputed)
    let freqsCos: MLXArray
    let freqsSin: MLXArray
    let melFreqsCos: MLXArray
    let melFreqsSin: MLXArray

    // Local encoder (6 Transformer layers)
    let localEncoderLayers: [KanadeTransformerBlock]
    let localEncoderNormW: MLXArray
    let localEncoderNormB: MLXArray

    // Conv downsample
    let convDownsampleW: MLXArray
    let convDownsampleB: MLXArray

    // FSQ quantizer
    let fsgProjInW: MLXArray
    let fsgProjInB: MLXArray
    let fsgProjOutW: MLXArray
    let fsgProjOutB: MLXArray

    // Global encoder
    let globalEncoderBackbone: GlobalEncoderBackbone
    let globalEncoderPooling: AttentiveStatsPool

    // Mel prenet (6 Transformer layers)
    let melPrenetLayers: [KanadeTransformerBlock]
    let melPrenetNormW: MLXArray
    let melPrenetNormB: MLXArray
    let melPrenetOutputProjW: MLXArray
    let melPrenetOutputProjB: MLXArray

    // Mel conv upsample
    let melConvUpsampleW: MLXArray
    let melConvUpsampleB: MLXArray

    // Mel decoder (6 AdaLN Transformer layers)
    let melDecoderLayers: [AdaLNTransformerBlock]
    let melDecoderNormCondW: MLXArray
    let melDecoderNormCondB: MLXArray
    let melDecoderOutputProjW: MLXArray
    let melDecoderOutputProjB: MLXArray

    // PostNet
    let postNetConvWeights: [MLXArray]
    let postNetConvBiases: [MLXArray]
    let postNetNormWeights: [MLXArray]
    let postNetNormBiases: [MLXArray]

    public init(weights: [String: MLXArray]) {
        // RoPE for local encoder and mel prenet (dim=768, 12 heads, headDim=64)
        let (fc768, fs768) = precomputeFreqsCis(dim: 64, maxSeqLen: 1024)
        self.freqsCos = fc768
        self.freqsSin = fs768

        // RoPE for mel decoder (dim=512, 8 heads, headDim=64)
        let (fc512, fs512) = precomputeFreqsCis(dim: 64, maxSeqLen: 1024)
        self.melFreqsCos = fc512
        self.melFreqsSin = fs512

        // Local encoder
        var localLayers: [KanadeTransformerBlock] = []
        for i in 0..<6 {
            localLayers.append(KanadeTransformerBlock(
                weights: weights, prefix: "local_encoder.layers.\(i)",
                nHeads: 12, headDim: 64
            ))
        }
        self.localEncoderLayers = localLayers
        self.localEncoderNormW = weights["local_encoder.norm.weight"]!
        self.localEncoderNormB = weights["local_encoder.norm.bias"]!

        // Conv downsample
        self.convDownsampleW = weights["conv_downsample.weight"]!
        self.convDownsampleB = weights["conv_downsample.bias"]!

        // FSQ
        self.fsgProjInW = weights["local_quantizer.proj_in.weight"]!
        self.fsgProjInB = weights["local_quantizer.proj_in.bias"]!
        self.fsgProjOutW = weights["local_quantizer.proj_out.weight"]!
        self.fsgProjOutB = weights["local_quantizer.proj_out.bias"]!

        // Global encoder
        self.globalEncoderBackbone = GlobalEncoderBackbone(weights: weights)
        self.globalEncoderPooling = AttentiveStatsPool(weights: weights, prefix: "global_encoder.pooling")

        // Mel prenet
        var prenetLayers: [KanadeTransformerBlock] = []
        for i in 0..<6 {
            prenetLayers.append(KanadeTransformerBlock(
                weights: weights, prefix: "mel_prenet.layers.\(i)",
                nHeads: 12, headDim: 64
            ))
        }
        self.melPrenetLayers = prenetLayers
        self.melPrenetNormW = weights["mel_prenet.norm.weight"]!
        self.melPrenetNormB = weights["mel_prenet.norm.bias"]!
        self.melPrenetOutputProjW = weights["mel_prenet.output_proj.weight"]!
        self.melPrenetOutputProjB = weights["mel_prenet.output_proj.bias"]!

        // Mel conv upsample (ConvTranspose1d)
        self.melConvUpsampleW = weights["mel_conv_upsample.weight"]!
        self.melConvUpsampleB = weights["mel_conv_upsample.bias"]!

        // Mel decoder
        var decoderLayers: [AdaLNTransformerBlock] = []
        for i in 0..<6 {
            decoderLayers.append(AdaLNTransformerBlock(
                weights: weights, prefix: "mel_decoder.layers.\(i)",
                dim: 512, nHeads: 8, headDim: 64
            ))
        }
        self.melDecoderLayers = decoderLayers
        self.melDecoderNormCondW = weights["mel_decoder.norm.condition_proj.1.weight"]!
        self.melDecoderNormCondB = weights["mel_decoder.norm.condition_proj.1.bias"]!
        self.melDecoderOutputProjW = weights["mel_decoder.output_proj.weight"]!
        self.melDecoderOutputProjB = weights["mel_decoder.output_proj.bias"]!

        // PostNet
        var convW: [MLXArray] = [], convB: [MLXArray] = []
        var normW: [MLXArray] = [], normB: [MLXArray] = []
        for i in 0..<4 {
            convW.append(weights["mel_postnet.convolutions.\(i).0.weight"]!)
            convB.append(weights["mel_postnet.convolutions.\(i).0.bias"]!)
            normW.append(weights["mel_postnet.convolutions.\(i).1.norm.weight"]!)
            normB.append(weights["mel_postnet.convolutions.\(i).1.norm.bias"]!)
        }
        self.postNetConvWeights = convW
        self.postNetConvBiases = convB
        self.postNetNormWeights = normW
        self.postNetNormBiases = normB
    }

    // MARK: - Encode (extract content or global embedding from SSL features)

    /// Encode content tokens from local SSL features (avg of layers 6, 9).
    public func encodeContent(localSSLFeatures: MLXArray) -> (embedding: MLXArray, indices: MLXArray) {
        var x = localSSLFeatures  // (B, T, 768)

        // Normalize: zero mean, unit variance per dimension
        let mean = MLX.mean(x, axis: 1, keepDims: true)
        let std = MLX.sqrt(MLX.mean((x - mean) * (x - mean), axis: 1, keepDims: true) + MLXArray(Float(1e-8)))
        x = (x - mean) / std

        // Local encoder (6 transformer layers with RoPE)
        for layer in localEncoderLayers {
            x = layer(x, freqsCos: freqsCos, freqsSin: freqsSin)
        }
        x = layerNorm(x, weight: localEncoderNormW, bias: localEncoderNormB)

        // Conv downsample: (B, T, 768) -> (B, 768, T) -> Conv1d -> (B, 768, T/2) -> (B, T/2, 768)
        let xT = x.transposed(0, 2, 1)
        let downsampled = MLX.conv1d(xT.transposed(0, 2, 1), convDownsampleW, stride: downsampleFactor, padding: 0)
            .transposed(0, 2, 1).transposed(0, 2, 1)
        // Fix: proper conv1d with correct dims
        let convIn = x.transposed(0, 2, 1)  // (B, 768, T)
        let convOut = MLX.conv1d(convIn.transposed(0, 2, 1), convDownsampleW, stride: downsampleFactor, padding: 0)
        let xDown = convOut  // (B, T/2, 768) after MLX conv1d format

        // Add bias
        let xDownBiased = xDown + convDownsampleB

        // FSQ quantize
        let (embedding, indices) = fsqQuantize(xDownBiased)
        return (embedding, indices)
    }

    /// Encode global speaker embedding from global SSL features (avg of layers 1, 2).
    public func encodeGlobal(globalSSLFeatures: MLXArray) -> MLXArray {
        // Global encoder backbone: ConvNeXt
        var x = globalEncoderBackbone(globalSSLFeatures)  // (B, T, 384)

        // Attentive stats pooling
        let xT = x.transposed(0, 2, 1)  // (B, 384, T)
        return globalEncoderPooling(xT)  // (B, 128)
    }

    // MARK: - Decode (mel spectrogram from content + speaker)

    /// Decode mel spectrogram from content embedding and global speaker embedding.
    /// contentEmbedding: (B, T_content, 768) from encodeContent
    /// globalEmbedding: (B, 128) from encodeGlobal
    /// melLength: target mel spectrogram length
    public func decode(contentEmbedding: MLXArray, globalEmbedding: MLXArray, melLength: Int) -> MLXArray {
        // Mel prenet (6 transformer layers)
        var x = contentEmbedding
        for layer in melPrenetLayers {
            x = layer(x, freqsCos: freqsCos, freqsSin: freqsSin)
        }
        x = layerNorm(x, weight: melPrenetNormW, bias: melPrenetNormB)
        x = MLX.matmul(x, melPrenetOutputProjW.transposed()) + melPrenetOutputProjB  // (B, T_content, 512)

        // Conv transpose upsample: (B, T_content, 512) -> (B, T_content * factor, 512)
        x = convTranspose1d(x, weight: melConvUpsampleW, bias: melConvUpsampleB,
                           stride: melUpsampleFactor)

        // Interpolate to exact mel length
        x = linearInterpolate(x, targetLength: melLength)

        // Mel decoder (6 AdaLN transformer layers conditioned on speaker embedding)
        let condition = globalEmbedding.expandedDimensions(axis: 1)  // (B, 1, 128)
        for layer in melDecoderLayers {
            x = layer(x, condition: condition, freqsCos: melFreqsCos, freqsSin: melFreqsSin)
        }

        // Final AdaLN norm (no gate, just shift+scale)
        let condActivated = silu(condition)
        let normParams = MLX.matmul(condActivated, melDecoderNormCondW.transposed()) + melDecoderNormCondB
        let shift = normParams[.ellipsis, 0..<melDim]
        let scale = normParams[.ellipsis, melDim...]
        x = layerNormNoAffine(x) * (MLXArray(Float(1)) + scale) + shift

        // Output projection to mel dims
        x = MLX.matmul(x, melDecoderOutputProjW.transposed()) + melDecoderOutputProjB  // (B, melLength, 100)

        // Transpose to (B, 100, melLength) for PostNet
        var mel = x.transposed(0, 2, 1)

        // PostNet: 4 Conv1d layers with residual
        mel = applyPostNet(mel)

        return mel  // (B, 100, melLength)
    }

    // MARK: - FSQ Quantization

    private func fsqQuantize(_ x: MLXArray) -> (embedding: MLXArray, indices: MLXArray) {
        // Project to FSQ dimensions: (B, T, 768) -> (B, T, 5)
        var z = MLX.matmul(x, fsgProjInW.transposed()) + fsgProjInB

        // Bound each dimension by its level
        let levels = fsgLevels
        let eps: Float = 1e-3

        // Apply FSQ bounding per dimension
        var bounded = z
        for (d, level) in levels.enumerated() {
            let halfL = Float(level - 1) * (1.0 - eps) / 2.0
            let offset: Float = (level % 2 == 0) ? 0.5 : 0.0
            let shift = (offset / halfL).isFinite ? Float(atan(offset / halfL)) : 0.0

            let dim = bounded[.ellipsis, d..<(d+1)]
            let shifted = dim + MLXArray(shift)
            let tanhed = MLX.tanh(shifted) * MLXArray(halfL) - MLXArray(offset)
            // Round with straight-through estimator (at inference, just round)
            let rounded = MLX.round(tanhed)
            // Normalize to [-1, 1]
            let normalized = rounded / MLXArray(Float(level / 2))

            // Replace dimension d
            if d == 0 {
                bounded = normalized
            } else {
                bounded = MLX.concatenated([bounded[.ellipsis, 0..<d], normalized], axis: -1)
            }
        }

        // Compute indices: weighted sum with basis [1, 8, 64, 512, 2560]
        // (for levels [8,8,8,5,5])
        var basis = [1]
        for i in 1..<levels.count {
            basis.append(basis[i-1] * levels[i-1])
        }
        // Scale back from [-1,1] to [0, level-1]
        var intCodes = bounded
        for (d, level) in levels.enumerated() {
            let dim = intCodes[.ellipsis, d..<(d+1)]
            let scaled = dim * MLXArray(Float(level / 2)) + MLXArray(Float(level / 2))
            if d == 0 {
                intCodes = scaled
            } else {
                intCodes = MLX.concatenated([intCodes[.ellipsis, 0..<d], scaled], axis: -1)
            }
        }

        // Project back to embedding space
        let embedding = MLX.matmul(bounded, fsgProjOutW.transposed()) + fsgProjOutB

        // Indices (for reference, not needed for voice conversion)
        let basisArray = MLXArray(basis.map { Float($0) })
        let indices = MLX.sum(intCodes * basisArray, axis: -1)

        return (embedding, indices)
    }

    // MARK: - PostNet

    private func applyPostNet(_ mel: MLXArray) -> MLXArray {
        // mel: (B, 100, T)
        let residual = mel
        var x = mel

        for i in 0..<4 {
            // Conv1d: (B, C, T) format
            let xIn = x.transposed(0, 2, 1)  // (B, T, C)
            var conv = MLX.conv1d(xIn, postNetConvWeights[i], stride: 1, padding: 3)
            conv = conv.transposed(0, 2, 1) + postNetConvBiases[i].reshaped([1, -1, 1])

            // LayerNorm on channel dim: (B, C, T) -> (B, T, C) -> LN -> (B, T, C) -> (B, C, T)
            let convT = conv.transposed(0, 2, 1)
            let normed = layerNorm(convT, weight: postNetNormWeights[i], bias: postNetNormBiases[i])
            x = normed.transposed(0, 2, 1)

            // Activation (tanh for layers 0-2, none for layer 3)
            if i < 3 {
                x = MLX.tanh(x)
            }
        }

        return x + residual
    }

    // MARK: - Helpers

    /// ConvTranspose1d (deconvolution).
    private func convTranspose1d(_ x: MLXArray, weight: MLXArray, bias: MLXArray, stride: Int) -> MLXArray {
        // x: (B, T, C_in)
        // weight: (C_in, kernel, C_out) in MLX format
        // Simple implementation via matrix multiply + reshape for stride-based upsampling
        let B = x.shape[0]
        let T = x.shape[1]
        let cIn = x.shape[2]

        // ConvTranspose1d with stride=S is equivalent to:
        // 1. Multiply each input by the weight kernel
        // 2. Overlap-add with stride spacing
        // For our case: kernel_size == stride, so no overlap — just tiled output

        // Reshape weight: (C_out, kernel, C_in) from PyTorch, transposed for MLX
        // After conversion: weight is (C_in, kernel, C_out) in MLX
        // Each input vector x[t] of size C_in produces stride output frames of size C_out

        // Simple implementation: x @ weight_reshaped -> unfold
        let cOut = weight.shape[0]  // After transpose in convert script this may differ
        let kernel = stride  // kernel_size == stride for our model

        // weight shape from conversion: (C_out, kernel, C_in/groups)
        // We need: for each input frame, produce `kernel` output frames
        // Reshape weight to (C_in, kernel * C_out)
        let wReshaped = weight.transposed(2, 1, 0).reshaped([cIn, kernel * cOut])
        let projected = MLX.matmul(x, wReshaped)  // (B, T, kernel * C_out)
        let unfolded = projected.reshaped([B, T * kernel, cOut])  // (B, T*stride, C_out)

        return unfolded + bias
    }

    /// Linear interpolation to target length.
    private func linearInterpolate(_ x: MLXArray, targetLength: Int) -> MLXArray {
        // x: (B, T, C)
        let T = x.shape[1]
        if T == targetLength { return x }

        let C = x.shape[2]
        let B = x.shape[0]
        let scale = Float(T - 1) / Float(max(targetLength - 1, 1))

        // Extract to CPU for interpolation
        let flat: [Float] = x.reshaped([-1]).asArray(Float.self)
        var output = [Float](repeating: 0, count: B * targetLength * C)

        for b in 0..<B {
            for t in 0..<targetLength {
                let srcIdx = Float(t) * scale
                let low = Int(srcIdx)
                let high = min(low + 1, T - 1)
                let frac = srcIdx - Float(low)
                for c in 0..<C {
                    let lowVal = flat[b * T * C + low * C + c]
                    let highVal = flat[b * T * C + high * C + c]
                    output[b * targetLength * C + t * C + c] = lowVal * (1 - frac) + highVal * frac
                }
            }
        }

        return MLXArray(output).reshaped([B, targetLength, C])
    }
}

// MARK: - Global Encoder Backbone (ConvNeXt)

public class GlobalEncoderBackbone {
    let embedWeight: MLXArray
    let embedBias: MLXArray
    let normWeight: MLXArray
    let normBias: MLXArray
    let blocks: [ConvNeXtBlock]
    let finalNormWeight: MLXArray
    let finalNormBias: MLXArray

    public init(weights: [String: MLXArray]) {
        self.embedWeight = weights["global_encoder.backbone.embed.weight"]!
        self.embedBias = weights["global_encoder.backbone.embed.bias"]!
        self.normWeight = weights["global_encoder.backbone.norm.weight"]!
        self.normBias = weights["global_encoder.backbone.norm.bias"]!

        var blockList: [ConvNeXtBlock] = []
        for i in 0..<4 {
            blockList.append(ConvNeXtBlock(
                weights: weights,
                prefix: "global_encoder.backbone.convnext.\(i)",
                channels: 384
            ))
        }
        self.blocks = blockList

        self.finalNormWeight = weights["global_encoder.backbone.final_layer_norm.weight"]!
        self.finalNormBias = weights["global_encoder.backbone.final_layer_norm.bias"]!
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: (B, T, 768)
        // Embed: Conv1d(768, 384, kernel=7, padding=3)
        var h = MLX.conv1d(x, embedWeight, stride: 1, padding: 3)  // (B, T, 384)
        h = h + embedBias

        // LayerNorm
        h = layerNorm(h, weight: normWeight, bias: normBias, eps: 1e-6)

        // Transpose for ConvNeXt blocks: (B, T, 384) -> (B, 384, T)
        h = h.transposed(0, 2, 1)

        // 4 ConvNeXt blocks
        for block in blocks {
            h = block(h)
        }

        // Final norm: (B, 384, T) -> (B, T, 384)
        h = h.transposed(0, 2, 1)
        h = layerNorm(h, weight: finalNormWeight, bias: finalNormBias, eps: 1e-6)

        return h  // (B, T, 384)
    }
}
