import Foundation
import MLX

// MARK: - Rotary Position Embeddings

/// Precompute RoPE frequency table.
/// Returns (maxSeqLen, dim/2) complex pairs stored as (cos, sin) interleaved.
public func precomputeFreqsCis(dim: Int, maxSeqLen: Int, theta: Float = 10000.0) -> (cos: MLXArray, sin: MLXArray) {
    let halfDim = dim / 2
    var freqs = [Float](repeating: 0, count: halfDim)
    for i in 0..<halfDim {
        freqs[i] = 1.0 / pow(theta, Float(2 * i) / Float(dim))
    }

    var cosTable = [Float](repeating: 0, count: maxSeqLen * halfDim)
    var sinTable = [Float](repeating: 0, count: maxSeqLen * halfDim)

    for t in 0..<maxSeqLen {
        for i in 0..<halfDim {
            let angle = Float(t) * freqs[i]
            cosTable[t * halfDim + i] = cos(angle)
            sinTable[t * halfDim + i] = sin(angle)
        }
    }

    return (
        cos: MLXArray(cosTable).reshaped([maxSeqLen, halfDim]),
        sin: MLXArray(sinTable).reshaped([maxSeqLen, halfDim])
    )
}

/// Apply RoPE to query/key tensors.
/// Input shape: (B, nHeads, T, headDim) or (B, T, nHeads, headDim)
/// freqsCos/freqsSin shape: (T, headDim/2)
public func applyRoPE(
    _ x: MLXArray,
    freqsCos: MLXArray,
    freqsSin: MLXArray,
    seqDim: Int = 2  // dimension containing sequence length
) -> MLXArray {
    let headDim = x.shape[x.ndim - 1]
    let halfDim = headDim / 2

    // Split into pairs: (B, nH, T, halfDim) each
    let x1 = x[.ellipsis, 0..<halfDim]
    let x2 = x[.ellipsis, halfDim...]

    // Broadcast freqs to match: need shape (1, 1, T, halfDim)
    let T = x.shape[seqDim]
    let cos = freqsCos[0..<T].reshaped([1, 1, T, halfDim])
    let sin = freqsSin[0..<T].reshaped([1, 1, T, halfDim])

    // Rotate: (x1 * cos - x2 * sin, x1 * sin + x2 * cos)
    let out1 = x1 * cos - x2 * sin
    let out2 = x1 * sin + x2 * cos

    return MLX.concatenated([out1, out2], axis: -1)
}

// MARK: - SwiGLU Feed-Forward Network

/// SwiGLU FFN: w2(silu(w1(x)) * w3(x))
public class SwiGLUFFN {
    let w1: MLXArray  // (hiddenDim, dim)
    let w2: MLXArray  // (dim, hiddenDim)
    let w3: MLXArray  // (hiddenDim, dim)

    public init(weights: [String: MLXArray], prefix: String) {
        self.w1 = weights["\(prefix).w1.weight"]!
        self.w2 = weights["\(prefix).w2.weight"]!
        self.w3 = weights["\(prefix).w3.weight"]!
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        // w1, w2, w3 are stored as (out, in) — use matmul with transpose
        let gate = MLX.matmul(x, w1.transposed())
        let up = MLX.matmul(x, w3.transposed())
        let activated = silu(gate) * up
        return MLX.matmul(activated, w2.transposed())
    }
}

// MARK: - Windowed Self-Attention (with RoPE)

/// Multi-head self-attention with optional window size and RoPE.
public class RoPEAttention {
    let wq: MLXArray  // (dim, dim)
    let wk: MLXArray
    let wv: MLXArray
    let wo: MLXArray
    let nHeads: Int
    let headDim: Int
    let scale: Float

    public init(weights: [String: MLXArray], prefix: String, nHeads: Int, headDim: Int) {
        self.wq = weights["\(prefix).wq.weight"]!
        self.wk = weights["\(prefix).wk.weight"]!
        self.wv = weights["\(prefix).wv.weight"]!
        self.wo = weights["\(prefix).wo.weight"]!
        self.nHeads = nHeads
        self.headDim = headDim
        self.scale = 1.0 / sqrt(Float(headDim))
    }

    public func callAsFunction(
        _ x: MLXArray,
        freqsCos: MLXArray,
        freqsSin: MLXArray
    ) -> MLXArray {
        let B = x.shape[0]
        let T = x.shape[1]

        // Project Q, K, V
        var q = MLX.matmul(x, wq.transposed()).reshaped([B, T, nHeads, headDim]).transposed(0, 2, 1, 3)
        var k = MLX.matmul(x, wk.transposed()).reshaped([B, T, nHeads, headDim]).transposed(0, 2, 1, 3)
        let v = MLX.matmul(x, wv.transposed()).reshaped([B, T, nHeads, headDim]).transposed(0, 2, 1, 3)

        // Apply RoPE
        q = applyRoPE(q, freqsCos: freqsCos, freqsSin: freqsSin)
        k = applyRoPE(k, freqsCos: freqsCos, freqsSin: freqsSin)

        // Scaled dot-product attention
        let scores = MLX.matmul(q, k.transposed(0, 1, 3, 2)) * MLXArray(scale)

        // Causal mask is NOT used for encoder self-attention in Kanade
        let attnWeights = MLX.softmax(scores, axis: -1)
        let attnOutput = MLX.matmul(attnWeights, v)

        // Reshape back: (B, nHeads, T, headDim) -> (B, T, dim)
        let dim = nHeads * headDim
        let output = attnOutput.transposed(0, 2, 1, 3).reshaped([B, T, dim])
        return MLX.matmul(output, wo.transposed())
    }
}

// MARK: - Transformer Block (Kanade-style, pre-norm with RoPE)

public class KanadeTransformerBlock {
    let attentionNorm: (MLXArray, MLXArray)  // (weight, bias)
    let attention: RoPEAttention
    let ffnNorm: (MLXArray, MLXArray)
    let ffn: SwiGLUFFN

    public init(weights: [String: MLXArray], prefix: String, nHeads: Int, headDim: Int) {
        self.attentionNorm = (
            weights["\(prefix).attention_norm.weight"]!,
            weights["\(prefix).attention_norm.bias"]!
        )
        self.attention = RoPEAttention(
            weights: weights, prefix: "\(prefix).attention",
            nHeads: nHeads, headDim: headDim
        )
        self.ffnNorm = (
            weights["\(prefix).ffn_norm.weight"]!,
            weights["\(prefix).ffn_norm.bias"]!
        )
        self.ffn = SwiGLUFFN(weights: weights, prefix: "\(prefix).feed_forward")
    }

    public func callAsFunction(
        _ x: MLXArray,
        freqsCos: MLXArray,
        freqsSin: MLXArray
    ) -> MLXArray {
        // Pre-norm attention
        let normX = layerNorm(x, weight: attentionNorm.0, bias: attentionNorm.1)
        let attnOut = attention(normX, freqsCos: freqsCos, freqsSin: freqsSin)
        let h = x + attnOut

        // Pre-norm FFN
        let normH = layerNorm(h, weight: ffnNorm.0, bias: ffnNorm.1)
        let ffnOut = ffn(normH)
        return h + ffnOut
    }
}

// MARK: - AdaLN Zero Transformer Block (for Mel Decoder)

public class AdaLNTransformerBlock {
    let attnCondProj: (MLXArray, MLXArray)  // (weight, bias) for SiLU -> Linear
    let attention: RoPEAttention
    let ffnCondProj: (MLXArray, MLXArray)
    let ffn: SwiGLUFFN
    let dim: Int

    public init(weights: [String: MLXArray], prefix: String, dim: Int, nHeads: Int, headDim: Int) {
        self.dim = dim
        self.attnCondProj = (
            weights["\(prefix).attention_norm.condition_proj.1.weight"]!,
            weights["\(prefix).attention_norm.condition_proj.1.bias"]!
        )
        self.attention = RoPEAttention(
            weights: weights, prefix: "\(prefix).attention",
            nHeads: nHeads, headDim: headDim
        )
        self.ffnCondProj = (
            weights["\(prefix).ffn_norm.condition_proj.1.weight"]!,
            weights["\(prefix).ffn_norm.condition_proj.1.bias"]!
        )
        self.ffn = SwiGLUFFN(weights: weights, prefix: "\(prefix).feed_forward")
    }

    public func callAsFunction(
        _ x: MLXArray,
        condition: MLXArray,  // (B, 1, condDim)
        freqsCos: MLXArray,
        freqsSin: MLXArray
    ) -> MLXArray {
        // AdaLN Zero for attention
        let attnParams = adaln(x, condition: condition, projWeight: attnCondProj.0, projBias: attnCondProj.1, dim: dim)
        let attnOut = attention(attnParams.modulated, freqsCos: freqsCos, freqsSin: freqsSin)
        let h = x + attnParams.gate * attnOut

        // AdaLN Zero for FFN
        let ffnParams = adaln(h, condition: condition, projWeight: ffnCondProj.0, projBias: ffnCondProj.1, dim: dim)
        let ffnOut = ffn(ffnParams.modulated)
        return h + ffnParams.gate * ffnOut
    }
}

// MARK: - ConvNeXt Block

public class ConvNeXtBlock {
    let dwconvWeight: MLXArray  // (channels, kernelSize, 1) after transpose
    let dwconvBias: MLXArray
    let normWeight: MLXArray
    let normBias: MLXArray
    let pwconv1Weight: MLXArray
    let pwconv1Bias: MLXArray
    let pwconv2Weight: MLXArray
    let pwconv2Bias: MLXArray
    let gamma: MLXArray
    let channels: Int

    public init(weights: [String: MLXArray], prefix: String, channels: Int) {
        self.channels = channels
        self.dwconvWeight = weights["\(prefix).dwconv.weight"]!
        self.dwconvBias = weights["\(prefix).dwconv.bias"]!
        self.normWeight = weights["\(prefix).norm.weight"]!
        self.normBias = weights["\(prefix).norm.bias"]!
        self.pwconv1Weight = weights["\(prefix).pwconv1.weight"]!
        self.pwconv1Bias = weights["\(prefix).pwconv1.bias"]!
        self.pwconv2Weight = weights["\(prefix).pwconv2.weight"]!
        self.pwconv2Bias = weights["\(prefix).pwconv2.bias"]!
        self.gamma = weights["\(prefix).gamma"]!
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: (B, channels, T) — conv layout
        let residual = x

        // Depthwise conv: groups=channels
        var h = MLX.conv1d(x.transposed(0, 2, 1), dwconvWeight, stride: 1, padding: 3, groups: channels)
        h = h.transposed(0, 2, 1) + dwconvBias.reshaped([1, channels, 1])

        // LayerNorm on channel dim: (B, C, T) -> (B, T, C) -> LN -> (B, T, C)
        h = h.transposed(0, 2, 1)
        h = layerNorm(h, weight: normWeight, bias: normBias)

        // Pointwise convs (as Linear)
        h = MLX.matmul(h, pwconv1Weight.transposed()) + pwconv1Bias
        h = gelu(h)
        h = MLX.matmul(h, pwconv2Weight.transposed()) + pwconv2Bias

        // Layer scale
        h = gamma * h

        // Back to (B, C, T)
        h = h.transposed(0, 2, 1)
        return residual + h
    }
}

// MARK: - Attentive Statistics Pooling

public class AttentiveStatsPool {
    let attn0Weight: MLXArray  // Conv1d(inputCh, attnCh, 1)
    let attn0Bias: MLXArray
    let attn2Weight: MLXArray  // Conv1d(attnCh, inputCh, 1)
    let attn2Bias: MLXArray
    let projWeight: MLXArray   // Linear(inputCh*2, outputCh)
    let projBias: MLXArray
    let normWeight: MLXArray
    let normBias: MLXArray

    public init(weights: [String: MLXArray], prefix: String) {
        self.attn0Weight = weights["\(prefix).attn.0.weight"]!
        self.attn0Bias = weights["\(prefix).attn.0.bias"]!
        self.attn2Weight = weights["\(prefix).attn.2.weight"]!
        self.attn2Bias = weights["\(prefix).attn.2.bias"]!
        self.projWeight = weights["\(prefix).proj.weight"]!
        self.projBias = weights["\(prefix).proj.bias"]!
        self.normWeight = weights["\(prefix).norm.weight"]!
        self.normBias = weights["\(prefix).norm.bias"]!
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: (B, channels, T)
        // Attention weights: Conv1d(ch, attnCh, 1) -> Tanh -> Conv1d(attnCh, ch, 1) -> Softmax
        var alpha = MLX.conv1d(x.transposed(0, 2, 1), attn0Weight, stride: 1, padding: 0)
        alpha = alpha.transposed(0, 2, 1) + attn0Bias.reshaped([1, -1, 1])
        alpha = MLX.tanh(alpha)
        alpha = MLX.conv1d(alpha.transposed(0, 2, 1), attn2Weight, stride: 1, padding: 0)
        alpha = alpha.transposed(0, 2, 1) + attn2Bias.reshaped([1, -1, 1])
        alpha = MLX.softmax(alpha, axis: 2)  // (B, channels, T)

        // Weighted mean and std
        let mean = MLX.sum(alpha * x, axis: 2)  // (B, channels)
        let variance = MLX.sum(alpha * x * x, axis: 2) - mean * mean
        let std = MLX.sqrt(MLX.maximum(variance, MLXArray(Float(1e-8))))

        // Concat mean + std -> project -> normalize
        let pooled = MLX.concatenated([mean, std], axis: 1)  // (B, channels*2)
        var out = MLX.matmul(pooled, projWeight.transposed()) + projBias
        out = layerNorm(out.expandedDimensions(axis: 1), weight: normWeight, bias: normBias).squeezed(axis: 1)
        return out  // (B, outputChannels)
    }
}

// MARK: - Helper Functions

/// Layer normalization.
public func layerNorm(_ x: MLXArray, weight: MLXArray, bias: MLXArray, eps: Float = 1e-5) -> MLXArray {
    let mean = MLX.mean(x, axis: -1, keepDims: true)
    let variance = MLX.mean((x - mean) * (x - mean), axis: -1, keepDims: true)
    let normalized = (x - mean) / MLX.sqrt(variance + MLXArray(eps))
    return weight * normalized + bias
}

/// Layer normalization without learnable params (for AdaLN).
public func layerNormNoAffine(_ x: MLXArray, eps: Float = 1e-5) -> MLXArray {
    let mean = MLX.mean(x, axis: -1, keepDims: true)
    let variance = MLX.mean((x - mean) * (x - mean), axis: -1, keepDims: true)
    return (x - mean) / MLX.sqrt(variance + MLXArray(eps))
}

/// AdaLN Zero: returns (modulated, gate).
public func adaln(
    _ x: MLXArray,
    condition: MLXArray,  // (B, 1, condDim)
    projWeight: MLXArray,
    projBias: MLXArray,
    dim: Int
) -> (modulated: MLXArray, gate: MLXArray) {
    let normalized = layerNormNoAffine(x)

    // SiLU(condition) -> Linear -> split into (shift, scale, gate)
    let condActivated = silu(condition)
    let params = MLX.matmul(condActivated, projWeight.transposed()) + projBias  // (B, 1, 3*dim)

    let shift = params[.ellipsis, 0..<dim]
    let scale = params[.ellipsis, dim..<(2*dim)]
    let gate = params[.ellipsis, (2*dim)...]

    let modulated = normalized * (MLXArray(Float(1)) + scale) + shift
    return (modulated: modulated, gate: gate)
}

/// GELU activation.
public func gelu(_ x: MLXArray) -> MLXArray {
    // Exact GELU: x * 0.5 * (1 + erf(x / sqrt(2)))
    return x * MLXArray(Float(0.5)) * (MLXArray(Float(1)) + MLX.erf(x * MLXArray(Float(1.0 / sqrt(2.0)))))
}

/// SiLU (Swish) activation.
public func silu(_ x: MLXArray) -> MLXArray {
    return x * MLX.sigmoid(x)
}
