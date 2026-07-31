//
//  Kokoro-tts-lib
//
import Foundation
import MLX
import MLXNN

/// Text encoder that transforms tokenized phoneme sequences into contextual embeddings.
///
/// The encoder processes text through three stages:
/// 1. **Embedding layer**: Converts token IDs to dense vectors
/// 2. **CNN layers**: Extract local features with weight normalization and layer normalization
/// 3. **Bidirectional LSTM**: Captures long-range dependencies in both directions
///
/// The output embeddings are used by the decoder to generate speech aligned with the input text.
final class TextEncoder {
  /// Embedding layer that converts token IDs to dense vectors
  let embedding: Embedding
  
  /// Stack of CNN blocks for local feature extraction
  /// Each block contains: [ConvWeighted, LayerNorm, Activation]
  let cnn: [[Module]]
  
  /// Bidirectional LSTM for capturing sequential dependencies
  let lstm: LSTM
  
  /// Initializes the text encoder with pretrained weights.
  /// - Parameters:
  ///   - weights: Dictionary of pretrained model weights
  ///   - channels: Number of channels in hidden layers
  ///   - kernelSize: Kernel size for convolutional layers
  ///   - depth: Number of CNN blocks to stack
  ///   - nSymbols: Size of the vocabulary (number of unique tokens)
  ///   - actv: Activation function (default: LeakyReLU with slope 0.2)
  init(weights: [String: MLXArray], channels: Int, kernelSize: Int, depth: Int, nSymbols _: Int, actv: Module = LeakyReLU(negativeSlope: 0.2)) {
    // Initialize embedding layer
    embedding = Embedding(weight: weights["text_encoder.embedding.weight"]!)
    
    // Calculate padding to maintain sequence length
    let padding = (kernelSize - 1) / 2

    // Build CNN layers with weight normalization and layer normalization
    var cnnLayers: [[Module]] = []
    for i in 0 ..< depth {
      cnnLayers.append([
        // Weight-normalized convolution
        ConvWeighted(
          weightG: weights["text_encoder.cnn.\(i).0.weight_g"]!,
          weightV: weights["text_encoder.cnn.\(i).0.weight_v"]!,
          bias: weights["text_encoder.cnn.\(i).0.bias"]!,
          padding: padding
        ),
        // Layer normalization for stability
        LayerNormInference(
          weight: weights["text_encoder.cnn.\(i).1.gamma"]!,
          bias: weights["text_encoder.cnn.\(i).1.beta"]!
        ),
        // Activation function
        actv,
      ])
    }
    cnn = cnnLayers

    // Initialize bidirectional LSTM
    lstm = LSTM(
      inputSize: channels,
      hiddenSize: channels / 2,  // Half size because bidirectional (forward + backward)
      wxForward: weights["text_encoder.lstm.weight_ih_l0"]!,
      whForward: weights["text_encoder.lstm.weight_hh_l0"]!,
      biasIhForward: weights["text_encoder.lstm.bias_ih_l0"]!,
      biasHhForward: weights["text_encoder.lstm.bias_hh_l0"]!,
      wxBackward: weights["text_encoder.lstm.weight_ih_l0_reverse"]!,
      whBackward: weights["text_encoder.lstm.weight_hh_l0_reverse"]!,
      biasIhBackward: weights["text_encoder.lstm.bias_ih_l0_reverse"]!,
      biasHhBackward: weights["text_encoder.lstm.bias_hh_l0_reverse"]!
    )
  }
  
  /// Forward pass. Encodes input token sequences into contextual embeddings.
  ///
  /// The encoding pipeline:
  /// 1. Convert tokens to embeddings
  /// 2. Apply masking to ignore padding positions
  /// 3. Process through CNN blocks for local features
  /// 4. Process through bidirectional LSTM for sequential context
  /// 5. Apply final masking and return
  ///
  /// - Parameters:
  ///   - x: Input token IDs [batch_size, sequence_length]
  ///   - inputLengths: Length of each sequence (unused but kept for interface compatibility)
  ///   - m: Mask indicating padding positions [batch_size, sequence_length]
  /// - Returns: Encoded text features [batch_size, channels, sequence_length]
  public func callAsFunction(_ x: MLXArray, inputLengths _: MLXArray, m: MLXArray) -> MLXArray {
    // Step 1: Convert token IDs to embeddings [batch, seq_len, embed_dim]
    var x = embedding(x)

    // Masks for both layouts, computed once.
    let mask = m.expandedDimensions(axis: 1)   // [batch, 1, seq] for channel-major
    let maskT = m.expandedDimensions(axis: 2)  // [batch, seq, 1] for seq-major

    // Apply mask to zero out padding positions
    x = MLX.where(maskT, 0.0, x)

    // Step 2: Process through CNN blocks. Every layer here operates in
    // [batch, seq_len, channels]; the previous implementation swapped axes
    // to and from channel-major around every conv/norm layer.
    for convBlock in cnn {
      for layer in convBlock {
        if let convWeighted = layer as? ConvWeighted {
          x = convWeighted(x, conv: MLX.conv1d)
          x = MLX.where(maskT, 0.0, x)
        } else if let layer = layer as? LayerNormInference {
          x = layer(x)
          x = MLX.where(maskT, 0.0, x)
        } else if let layer = layer as? LeakyReLU {
          // LeakyReLU(0) == 0, so already-masked rows stay zero — no re-mask.
          x = layer(x)
        } else {
          fatalError("Unsupported layer type")
        }
      }
    }

    // Step 3: Bidirectional LSTM (also seq-major input)
    let (lstmOutput, _) = lstm(x)
    // Transpose back to [batch, channels, seq_len] for the caller
    x = MLX.swappedAxes(lstmOutput, 2, 1)

    // Apply final mask and return (the zeros-then-_updateInternal pad here
    // was dead: _updateInternal replaced the freshly allocated buffer).
    return MLX.where(mask, 0.0, x)
  }
}
