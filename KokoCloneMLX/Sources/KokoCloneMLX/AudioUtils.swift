import Foundation
import MLX
import MLXFFT

// MARK: - WAV File I/O

/// Load a WAV file and return mono Float32 samples normalized to [-1, 1].
public func loadWAV(url: URL) throws -> (samples: MLXArray, sampleRate: Int) {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else { throw KokoCloneError.invalidAudio("WAV too short") }

    // Parse WAV header
    let riff = String(data: data[0..<4], encoding: .ascii)
    guard riff == "RIFF" else { throw KokoCloneError.invalidAudio("Not a RIFF file") }

    let format = String(data: data[8..<12], encoding: .ascii)
    guard format == "WAVE" else { throw KokoCloneError.invalidAudio("Not a WAVE file") }

    // Find fmt chunk
    var offset = 12
    var sampleRate = 0
    var bitsPerSample = 0
    var numChannels = 0
    var audioFormat: UInt16 = 0
    var dataStart = 0
    var dataSize = 0

    while offset < data.count - 8 {
        let chunkID = String(data: data[offset..<offset+4], encoding: .ascii) ?? ""
        let chunkSize = data.withUnsafeBytes { ptr -> Int in
            Int(ptr.load(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
        }

        if chunkID == "fmt " {
            audioFormat = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 8, as: UInt16.self).littleEndian }
            numChannels = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset + 10, as: UInt16.self).littleEndian })
            sampleRate = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: UInt32.self).littleEndian })
            bitsPerSample = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset + 22, as: UInt16.self).littleEndian })
        } else if chunkID == "data" {
            dataStart = offset + 8
            dataSize = chunkSize
            break
        }
        offset += 8 + chunkSize
        if chunkSize % 2 != 0 { offset += 1 } // Pad byte
    }

    guard audioFormat == 1, bitsPerSample == 16, dataStart > 0 else {
        throw KokoCloneError.invalidAudio("Only PCM 16-bit WAV supported (got format=\(audioFormat) bits=\(bitsPerSample))")
    }

    let sampleCount = dataSize / 2
    var floats = [Float](repeating: 0, count: sampleCount)
    data.withUnsafeBytes { ptr in
        for i in 0..<sampleCount {
            let int16 = ptr.load(fromByteOffset: dataStart + i * 2, as: Int16.self).littleEndian
            floats[i] = Float(int16) / Float(Int16.max)
        }
    }

    // Convert to mono if stereo
    if numChannels == 2 {
        let monoCount = sampleCount / 2
        var mono = [Float](repeating: 0, count: monoCount)
        for i in 0..<monoCount {
            mono[i] = (floats[i * 2] + floats[i * 2 + 1]) * 0.5
        }
        return (MLXArray(mono), sampleRate)
    }

    return (MLXArray(floats), sampleRate)
}

/// Write mono Float32 samples to a WAV file.
public func saveWAV(samples: MLXArray, sampleRate: Int, to url: URL) throws {
    let floats: [Float] = samples.asArray(Float.self)
    let dataSize = UInt32(floats.count * 2)
    let fileSize = UInt32(36) + dataSize

    var wav = Data()
    wav.reserveCapacity(Int(44 + dataSize))

    // RIFF header
    wav.append("RIFF".data(using: .ascii)!)
    wav.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
    wav.append("WAVE".data(using: .ascii)!)

    // fmt chunk
    wav.append("fmt ".data(using: .ascii)!)
    wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // PCM
    wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // Mono
    wav.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })  // Block align
    wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }) // Bits

    // data chunk
    wav.append("data".data(using: .ascii)!)
    wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
    for sample in floats {
        let clamped = max(-1.0, min(1.0, sample))
        var int16 = Int16(clamped * Float(Int16.max))
        wav.append(withUnsafeBytes(of: int16.littleEndian) { Data($0) })
    }

    try wav.write(to: url)
}

// MARK: - Resampling

/// Simple linear interpolation resampler (24kHz -> 16kHz or vice versa).
public func resample(_ audio: MLXArray, fromRate: Int, toRate: Int) -> MLXArray {
    if fromRate == toRate { return audio }
    let inputLen = audio.shape[audio.ndim - 1]
    let outputLen = Int(Double(inputLen) * Double(toRate) / Double(fromRate))
    guard outputLen > 0 else { return MLXArray.zeros([0]) }

    // Use linear interpolation
    let scale = Float(inputLen - 1) / Float(max(outputLen - 1, 1))
    var output = [Float](repeating: 0, count: outputLen)
    let inputFloats: [Float] = audio.reshaped([-1]).asArray(Float.self)

    for i in 0..<outputLen {
        let srcIdx = Float(i) * scale
        let low = Int(srcIdx)
        let high = min(low + 1, inputLen - 1)
        let frac = srcIdx - Float(low)
        output[i] = inputFloats[low] * (1 - frac) + inputFloats[high] * frac
    }
    return MLXArray(output)
}

// MARK: - Mel Spectrogram

/// Compute mel spectrogram from audio waveform.
/// Returns shape (1, n_mels, T) matching Vocos input format.
public func melSpectrogram(
    audio: MLXArray,
    nFFT: Int = 1024,
    hopLength: Int = 256,
    nMels: Int = 100,
    sampleRate: Int = 24000,
    melFilterbank: MLXArray  // shape (n_freqs, n_mels) = (513, 100)
) -> MLXArray {
    // Pad for center mode: nFFT/2 on each side using concatenation
    // (MLX Swift may not have a `pad` function — use concat with zeros)
    let padAmount = nFFT / 2
    let padLeft = MLXArray.zeros([padAmount])
    let padRight = MLXArray.zeros([padAmount])
    let padded = MLX.concatenated([padLeft, audio.reshaped([-1]), padRight], axis: 0)

    // STFT using rfft on windowed frames
    let signal: [Float] = padded.asArray(Float.self)
    let numFrames = (signal.count - nFFT) / hopLength + 1
    let nFreqs = nFFT / 2 + 1

    // Hann window
    var window = [Float](repeating: 0, count: nFFT)
    for i in 0..<nFFT {
        window[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(nFFT)))
    }

    // Extract frames and apply window
    var frames = [Float](repeating: 0, count: numFrames * nFFT)
    for f in 0..<numFrames {
        let start = f * hopLength
        for i in 0..<nFFT {
            frames[f * nFFT + i] = signal[start + i] * window[i]
        }
    }

    // Compute rfft per frame using MLX
    let framesArray = MLXArray(frames).reshaped([numFrames, nFFT])
    let spectrum = MLXFFT.rfft(framesArray, axis: -1)  // (numFrames, nFreqs) complex

    // Power spectrogram (magnitude)
    let real = spectrum.realPart()
    let imag = spectrum.imaginaryPart()
    let magnitudes = MLX.sqrt(real * real + imag * imag)  // (numFrames, nFreqs)

    // Apply mel filterbank: (numFrames, nFreqs) @ (nFreqs, nMels) -> (numFrames, nMels)
    let melSpec = MLX.matmul(magnitudes, melFilterbank)

    // Log scale with floor
    let logMel = MLX.log(MLX.maximum(melSpec, MLXArray(Float(1e-5))))

    // Transpose to (1, nMels, numFrames) for Vocos
    return logMel.transposed(0, 1).expandedDimensions(axis: 0)
}

// MARK: - Errors

public enum KokoCloneError: LocalizedError {
    case invalidAudio(String)
    case modelNotLoaded(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAudio(let msg): return "Invalid audio: \(msg)"
        case .modelNotLoaded(let msg): return "Model not loaded: \(msg)"
        case .conversionFailed(let msg): return "Conversion failed: \(msg)"
        }
    }
}
