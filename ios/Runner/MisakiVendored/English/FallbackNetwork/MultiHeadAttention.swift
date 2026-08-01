import Foundation
import MLX
import MLXNN

nonisolated final class MultiHeadAttention: Module {
    let numHeads: Int
    let dModel: Int
    let headDim: Int
    
    let qProj: Linear
    let kProj: Linear
    let vProj: Linear
    let outProj: Linear
    
    init(dModel: Int, numHeads: Int, modelKey: String, weights: [String: MLXArray]) {
      self.dModel = dModel
      self.numHeads = numHeads
      self.headDim = dModel / numHeads
      
      self.qProj = Linear(weight: weights[modelKey + ".q_proj.weight"]!, bias:  weights[modelKey + ".q_proj.bias"])
      self.kProj = Linear(weight: weights[modelKey + ".k_proj.weight"]!, bias:  weights[modelKey + ".k_proj.bias"])
      self.vProj = Linear(weight: weights[modelKey + ".v_proj.weight"]!, bias:  weights[modelKey + ".v_proj.bias"])
      self.outProj = Linear(weight: weights[modelKey + ".out_proj.weight"]!, bias:  weights[modelKey + ".out_proj.bias"])
        
      super.init()
    }
    
    /// Project key/value once for reuse across incremental decode steps.
    /// Cross-attention K/V depend only on the encoder output; self-attention
    /// K/V for a new token are appended to a running cache.
    func projectKV(_ kv: MLXArray) -> (k: MLXArray, v: MLXArray) {
      let batchSize = kv.shape[0]
      let k = kProj(kv).reshaped([batchSize, -1, numHeads, headDim]).transposed(0, 2, 1, 3)
      let v = vProj(kv).reshaped([batchSize, -1, numHeads, headDim]).transposed(0, 2, 1, 3)
      return (k, v)
    }

    /// Attention for the newest position only, against precomputed K/V.
    /// Identical math to callAsFunction with the same K/V rows.
    func step(_ query: MLXArray, k: MLXArray, v: MLXArray) -> MLXArray {
      let batchSize = query.shape[0]
      let seqLen = query.shape[1]
      let q = qProj(query).reshaped([batchSize, seqLen, numHeads, headDim]).transposed(0, 2, 1, 3)

      let scale = Float(1.0 / sqrt(Double(headDim)))
      let scores = matmul(q, k.transposed(0, 1, 3, 2)) * scale
      let attnWeights = softmax(scores, axis: -1)
      let attnOutput = matmul(attnWeights, v)

      let output = attnOutput.transposed(0, 2, 1, 3).reshaped([batchSize, seqLen, dModel])
      return outProj(output)
    }

    func callAsFunction(_ query: MLXArray, key: MLXArray? = nil, value: MLXArray? = nil, mask: MLXArray? = nil) -> MLXArray {
      let key = key ?? query
      let value = value ?? query
            
      let batchSize = query.shape[0]
      let seqLen = query.shape[1]
        
      // Project and reshape
      let q = qProj(query).reshaped([batchSize, seqLen, numHeads, headDim]).transposed(0, 2, 1, 3)
      let k = kProj(key).reshaped([batchSize, -1, numHeads, headDim]).transposed(0, 2, 1, 3)
      let v = vProj(value).reshaped([batchSize, -1, numHeads, headDim]).transposed(0, 2, 1, 3)
        
      // Scaled dot-product attention
      let scale = Float(1.0 / sqrt(Double(headDim)))
      var scores = matmul(q, k.transposed(0, 1, 3, 2)) * scale
        
      if let mask {
          scores = scores + mask
      }
        
      let attnWeights = softmax(scores, axis: -1)
      let attnOutput = matmul(attnWeights, v)
      
      // Reshape and project
      let output = attnOutput.transposed(0, 2, 1, 3).reshaped([batchSize, seqLen, dModel])
      return outProj(output)
    }
}
