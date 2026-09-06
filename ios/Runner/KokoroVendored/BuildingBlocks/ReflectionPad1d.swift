//
//  Kokoro-tts-lib
//
import Foundation
import MLX
import MLXNN

class ReflectionPad1d: Module {
  private let leftPadding: Int
  private let rightPadding: Int

  init(padding: (Int, Int)) {
    leftPadding = padding.0
    rightPadding = padding.1
  }

  func callAsFunction(_ x: MLXArray) -> MLXArray {
    precondition(x.ndim == 3, "ReflectionPad1d expects a 3D NCL tensor")
    precondition(
      leftPadding >= 0 && rightPadding >= 0 &&
        leftPadding < x.shape[2] && rightPadding < x.shape[2],
      "Reflection padding must be non-negative and smaller than the input width"
    )

    var parts: [MLXArray] = []
    if leftPadding > 0 {
      let left = x[0..., 0..., 1 ..< leftPadding + 1]
      parts.append(left[0..., 0..., .stride(by: -1)])
    }
    parts.append(x)
    if rightPadding > 0 {
      let right = x[0..., 0..., -(rightPadding + 1) ..< -1]
      parts.append(right[0..., 0..., .stride(by: -1)])
    }
    return MLX.concatenated(parts, axis: 2)
  }
}
