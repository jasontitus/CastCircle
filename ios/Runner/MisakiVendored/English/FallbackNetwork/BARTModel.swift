import Foundation
import MLX
import MLXNN
import MLXRandom

nonisolated final class BARTModel: Module {
  let config: BARTConfig
  let sharedEmbedding: Embedding
  let encoderPositionalEmbedding: Embedding
  let decoderPositionalEmbedding: Embedding
  let encoderLayers: [BARTEncoderLayer]
  let decoderLayers: [BARTDecoderLayer]
  let encoderNorm: LayerNorm
  let decoderNorm: LayerNorm
  let lmHead: Linear
  let logitBias: MLXArray

  /// Position ids 2..<(maxPositions+2), built once — encode/decode slice it
  /// instead of rebuilding an arange per call.
  let positionIds: MLXArray

  init(config: BARTConfig, weights: [String: MLXArray]) {
    self.config = config
    
    // Shared embedding for encoder and decoder
    self.sharedEmbedding = Embedding(weight: weights["model.shared.weight"]!)
    
    // Positional embeddings
    self.encoderPositionalEmbedding = Embedding(weight: weights["model.encoder.embed_positions.weight"]!)
    self.decoderPositionalEmbedding = Embedding(weight: weights["model.decoder.embed_positions.weight"]!)
      
    // Encoder layers
    self.encoderLayers = (0..<config.encoderLayers).map { index in
      BARTEncoderLayer(
        dModel: config.dModel,
        numHeads: config.encoderAttentionHeads,
        dFF: config.encoderFFNDim,
        modelKey: "model.encoder.layers.\(index)",
        weights: weights)
    }
      
    // Decoder layers
    self.decoderLayers = (0..<config.decoderLayers).map { index in
      BARTDecoderLayer(
        dModel: config.dModel,
        numHeads: config.decoderAttentionHeads,
        dFF: config.decoderFFNDim,
        modelKey: "model.decoder.layers.\(index)",
        weights: weights)
    }
      
    // Layer norms
    self.encoderNorm = BARTLayerNorm(
      dimensions: config.dModel,
      weight: weights["model.encoder.layernorm_embedding.weight"]!,
      bias: weights["model.encoder.layernorm_embedding.bias"]!
    )
    self.decoderNorm = BARTLayerNorm(
      dimensions: config.dModel,
      weight: weights["model.decoder.layernorm_embedding.weight"]!,
      bias: weights["model.decoder.layernorm_embedding.bias"]!
    )
      
    // Language model head
    self.lmHead = Linear(weight: weights["model.shared.weight"]!, bias: nil)
    
    // This is not used
    self.logitBias = weights["final_logits_bias"]!

    self.positionIds =
      (MLXArray(0..<config.maxPositionEmbeddings) + 2).reshaped([1, config.maxPositionEmbeddings])

    super.init()
  }
    
  func encode(_ inputIds: MLXArray, mask: MLXArray? = nil) -> MLXArray {
    let seqLen = inputIds.shape[1]
    let positions = positionIds[0..., 0..<seqLen]
        
    // Embeddings
    var hidden = sharedEmbedding(inputIds)
    let embedPos = encoderPositionalEmbedding(positions)
            
    hidden = hidden + embedPos
    hidden = encoderNorm(hidden)
    
    // Encoder layers
    for layer in encoderLayers {
      hidden = layer(hidden, mask: mask)
    }
    
    return hidden
  }
    
  func decode(
    _ inputIds: MLXArray,
    encoderOutput: MLXArray,
    selfMask: MLXArray? = nil,
    crossMask: MLXArray? = nil) -> MLXArray
  {
    let seqLen = inputIds.shape[1]
    let positions = positionIds[0..., 0..<seqLen]

    // Embeddings
    var hidden = sharedEmbedding(inputIds)
    let embedPositions = decoderPositionalEmbedding(positions)
    
    hidden = hidden + embedPositions
    hidden = decoderNorm(hidden)
    
    // Decoder layers
    for layer in decoderLayers {
      hidden = layer(hidden, encoderOutput: encoderOutput, selfMask: selfMask, crossMask: crossMask)
    }
    
    return lmHead(hidden) + logitBias
  }
    
  /// Greedy decode with KV caching: each step embeds only the newest token,
  /// runs it against per-layer self-attention caches and cross-attention K/V
  /// projected once from the encoder output, and projects only that single
  /// position through the LM head. The previous implementation re-ran the
  /// decoder over the entire growing prefix and projected every position
  /// each step — O(n^2) work per word.
  func generate(inputIds: MLXArray, maxLength: Int = 50, temperature: Float = 1.0) -> MLXArray {
    // Encode input
    let encoderOutput = encode(inputIds)

    // Cross-attention K/V depend only on the encoder output — project once.
    let crossKV = decoderLayers.map { $0.crossAttn.projectKV(encoderOutput) }
    var selfCaches = [(k: MLXArray, v: MLXArray)?](repeating: nil, count: decoderLayers.count)

    // Start with BOS token
    var nextToken = Int32(config.bosTokenId)
    var generatedTokens: [Int32] = []

    for i in 0..<maxLength {
      if i == maxLength - 1 {
        generatedTokens.append(Int32(config.eosTokenId))
        break
      }

      // Embed only the newest token; earlier positions live in the caches.
      // Token generated at step i sits at sequence index i → position i+2.
      let tokenArray = MLXArray([nextToken]).reshaped([1, 1])
      let positions = positionIds[0..., i..<(i + 1)]
      var hidden = sharedEmbedding(tokenArray) + decoderPositionalEmbedding(positions)
      hidden = decoderNorm(hidden)

      for (index, layer) in decoderLayers.enumerated() {
        hidden = layer.step(
          hidden,
          crossK: crossKV[index].k,
          crossV: crossKV[index].v,
          selfCache: &selfCaches[index])
      }

      // LM head over the single newest position (was: every position).
      let logits = lmHead(hidden) + logitBias
      let nextTokenLogits = logits[0, 0]

      // Apply temperature
      let scaledLogits = nextTokenLogits / temperature

      // Sample next token, take the max probability value
      let next = scaledLogits.argMax().item(Int32.self)

      // Stop if EOS token
      if next == config.eosTokenId {
          break
      }

      generatedTokens.append(next)
      nextToken = next
    }

    return MLXArray(generatedTokens)
  }
}
