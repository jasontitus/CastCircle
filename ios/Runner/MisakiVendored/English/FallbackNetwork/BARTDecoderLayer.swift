import Foundation
import MLX
import MLXNN

nonisolated final class BARTDecoderLayer: Module {
  let selfAttn: MultiHeadAttention
  let selfAttnNorm: LayerNorm
  let crossAttn: MultiHeadAttention
  let crossAttnNorm: LayerNorm
  let ffn: FeedForward
  let ffnNorm: LayerNorm

  init(dModel: Int, numHeads: Int, dFF: Int, modelKey: String, weights: [String: MLXArray]) {
    self.selfAttn = MultiHeadAttention(dModel: dModel, numHeads: numHeads, modelKey: modelKey + ".self_attn", weights: weights)
    self.selfAttnNorm = BARTLayerNorm(
      dimensions: dModel,
      weight: weights[modelKey + ".self_attn_layer_norm.weight"]!,
      bias: weights[modelKey + ".self_attn_layer_norm.bias"]!)
    
    self.crossAttn = MultiHeadAttention(dModel: dModel, numHeads: numHeads, modelKey: modelKey + ".encoder_attn", weights: weights)
    self.crossAttnNorm = BARTLayerNorm(
      dimensions: dModel,
      weight: weights[modelKey + ".encoder_attn_layer_norm.weight"]!,
      bias: weights[modelKey + ".encoder_attn_layer_norm.bias"]!)
    
    self.ffn = FeedForward(
      weight1: weights[modelKey + ".fc1.weight"]!,
      bias1: weights[modelKey + ".fc1.bias"],
      weight2: weights[modelKey + ".fc2.weight"]!,
      bias2: weights[modelKey + ".fc2.bias"])
    
    self.ffnNorm = BARTLayerNorm(
      dimensions: dModel,
      weight: weights[modelKey + ".final_layer_norm.weight"]!,
      bias: weights[modelKey + ".final_layer_norm.bias"]!)
    
    super.init()
  }
    
    /// Incremental decode step: self-attention runs the newest position
    /// against a running K/V cache; cross-attention reuses K/V projected
    /// once from the encoder output. With the shipped single-decoder-layer
    /// configs this is exactly equivalent to re-running callAsFunction over
    /// the full prefix and reading the last position (layer-input K/V come
    /// straight from the embeddings, so cached and recomputed values match).
    func step(
      _ x: MLXArray,
      crossK: MLXArray,
      crossV: MLXArray,
      selfCache: inout (k: MLXArray, v: MLXArray)?
    ) -> MLXArray {
      var (k, v) = selfAttn.projectKV(x)
      if let cache = selfCache {
        k = concatenated([cache.k, k], axis: 2)
        v = concatenated([cache.v, v], axis: 2)
      }
      selfCache = (k, v)

      let attnOutput = selfAttn.step(x, k: k, v: v)
      var output = selfAttnNorm(x + attnOutput)

      let crossOutput = crossAttn.step(output, k: crossK, v: crossV)
      output = crossAttnNorm(output + crossOutput)

      let ffnOutput = ffn(output)
      output = ffnNorm(output + ffnOutput)

      return output
    }

    func callAsFunction(_ x: MLXArray, encoderOutput: MLXArray, selfMask: MLXArray? = nil, crossMask: MLXArray? = nil) -> MLXArray {
      // Self-attention with residual
      let attnOutput = selfAttn(x, mask: selfMask)
      var output = selfAttnNorm(x + attnOutput)
            
      // Cross-attention with residual
      let crossOutput = crossAttn(output, key: encoderOutput, value: encoderOutput, mask: crossMask)
      output = crossAttnNorm(output + crossOutput)
                  
      // Feed-forward with residual
      let ffnOutput = ffn(output)
      output = ffnNorm(output + ffnOutput)
      
      return output
    }
}
