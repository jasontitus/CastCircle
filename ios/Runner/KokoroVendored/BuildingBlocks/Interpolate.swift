//
//  Kokoro-tts-lib
//
import Foundation
import MLX
import MLXNN

func interpolate(
  input: MLXArray,
  size: [Int]? = nil,
  scaleFactor: [Float]? = nil,
  mode: String = "nearest",
  alignCorners: Bool? = nil
) -> MLXArray {
  let ndim = input.ndim
  if ndim < 3 {
    fatalError("Expected at least 3D input (N, C, D1), got \(ndim)D")
  }

  let spatialDims = ndim - 2

  // Handle size and scaleFactor
  if size != nil && scaleFactor != nil {
    fatalError("Only one of size or scaleFactor should be defined")
  } else if size == nil && scaleFactor == nil {
    fatalError("One of size or scaleFactor must be defined")
  }

  // Calculate output size from scale factor if needed
  var outputSize: [Int] = []
  if let scaleFactor = scaleFactor {
    let factors = scaleFactor.count == 1 ? Array(repeating: scaleFactor[0], count: spatialDims) : scaleFactor

    for i in 0 ..< spatialDims {
      // Use ceiling instead of floor to match PyTorch behavior
      let currSize = max(1, Int(ceil(Float(input.shape[i + 2]) * factors[i])))
      outputSize.append(currSize)
    }
  } else if let size = size {
    outputSize = size.count == 1 ? Array(repeating: size[0], count: spatialDims) : size
  }

  // Handle 1D case (N, C, W)
  if spatialDims == 1 {
    return interpolate1d(input: input, size: outputSize[0], mode: mode, alignCorners: alignCorners)
  } else {
    fatalError("Only 1D interpolation currently supported, got \(spatialDims)D")
  }
}

func interpolate1d(
  input: MLXArray,
  size: Int,
  mode: String = "linear",
  alignCorners: Bool? = nil
) -> MLXArray {
  let shape = input.shape
  let batchSize = shape[0]
  let channels = shape[1]
  let inWidth = shape[2]

  let outputSize = max(1, size)
  let inputWidth = max(1, inWidth)

  if mode == "nearest" {
    if outputSize == 1 {
      let indices = MLXArray(converting: [0]).asType(.int32)
      return input[0..., 0..., indices]
    } else {
      let scale = Float(inputWidth) / Float(outputSize)
      let indices = MLX.floor(MLXArray(0 ..< outputSize).asType(.float32) * scale).asType(.int32)
      let clippedIndices = MLX.clip(indices, min: 0, max: inputWidth - 1)
      return input[0..., 0..., clippedIndices]
    }
  }

  // Linear interpolation
  var x: MLXArray
  if alignCorners == true && outputSize > 1 {
    x = MLXArray(0 ..< outputSize).asType(.float32) * (Float(inputWidth - 1) / Float(outputSize - 1))
  } else {
    if outputSize == 1 {
      x = MLXArray(converting: [0.0]).asType(.float32)
    } else {
      x = MLXArray(0 ..< outputSize).asType(.float32) * (Float(inputWidth) / Float(outputSize))
      if alignCorners != true {
        x = x + 0.5 * (Float(inputWidth) / Float(outputSize)) - 0.5
      }
    }
  }

  if inputWidth == 1 {
    let outputShape = [batchSize, channels, outputSize]
    return MLX.broadcast(input, to: outputShape)
  }

  // Clamp the low index: in upsampling the first output positions map to
  // x < 0, and floor gives -1, which MLX negative-indexing WRAPS to the
  // last input sample — blending the final (largest) phase value into the
  // start of the output. Via SineGen this was a ~150-sample decaying phase
  // glitch at the onset of every voiced utterance. Clamping to 0 makes the
  // edge replicate the first sample instead (standard align_corners=false
  // edge handling). NB: intentional audio change, onset-only.
  let xLow = MLX.clip(
    MLX.floor(x).asType(.int32), min: MLXArray(0, dtype: .int32),
    max: MLXArray(inputWidth - 1, dtype: .int32))
  let xHigh = MLX.minimum(xLow + 1, MLXArray(inputWidth - 1, dtype: .int32))
  let xFrac = MLX.clip(x - xLow.asType(.float32), min: 0, max: 1)

  let yLow = input[0..., 0..., xLow]
  let yHigh = input[0..., 0..., xHigh]

  let oneMinusXFrac = 1 - xFrac
  let output = yLow * oneMinusXFrac.expandedDimensions(axis: 0).expandedDimensions(axis: 0) +
    yHigh * xFrac.expandedDimensions(axis: 0).expandedDimensions(axis: 0)

  return output
}
