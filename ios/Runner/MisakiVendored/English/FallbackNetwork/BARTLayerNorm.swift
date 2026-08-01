import Foundation
import MLX
import MLXNN

final class BARTLayerNorm : LayerNorm {
  public init(dimensions: Int, weight: MLXArray, bias: MLXArray) {
    super.init(dimensions: dimensions)

    // Bulk tensor assignment — the previous per-element copy created two
    // graph nodes per element per norm at model init.
    self.weight!._updateInternal(weight)
    self.bias!._updateInternal(bias)
  }
}
