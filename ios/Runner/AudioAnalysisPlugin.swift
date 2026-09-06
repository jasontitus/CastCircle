import Flutter
import AVFoundation

/// Native plugin that measures the loudness of a recorded audio file so the
/// Dart side can normalize playback volume across cast recordings.
///
/// Reads the file's PCM via AVAudioFile in fixed-size chunks and returns
/// peak/RMS in dBFS. Results are cached on the Dart side keyed by path.
class AudioAnalysisPlugin: NSObject {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/audio_analysis",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "loudness":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'path' argument",
                                    details: nil))
                return
            }
            loudness(path: path, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Returns ["rmsDbfs": Double, "peakDbfs": Double], or nil if the file can't
    /// be decoded (the Dart side treats nil as "no normalization").
    private func loudness(path: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: path)

            guard let file = try? AVAudioFile(forReading: url) else {
                DispatchQueue.main.async { result(nil) }
                return
            }

            let format = file.processingFormat
            let channels = Int(format.channelCount)
            let chunkFrameCount: AVAudioFrameCount = 32 * 1024
            guard file.length > 0,
                  channels > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: chunkFrameCount
                  ) else {
                DispatchQueue.main.async { result(nil) }
                return
            }

            var sampleCount: UInt64 = 0
            var sumSquares: Double = 0
            var peak: Float = 0

            do {
                while file.framePosition < file.length {
                    let remaining = file.length - file.framePosition
                    let requestedFrames = AVAudioFrameCount(
                        min(AVAudioFramePosition(chunkFrameCount), remaining)
                    )
                    try file.read(into: buffer, frameCount: requestedFrames)

                    let frameCount = Int(buffer.frameLength)
                    guard frameCount > 0,
                          let channelData = buffer.floatChannelData else {
                        break
                    }

                    for channel in 0..<channels {
                        let samples = channelData[channel]
                        for frame in 0..<frameCount {
                            let sample = samples[frame]
                            sumSquares += Double(sample) * Double(sample)
                            peak = max(peak, abs(sample))
                        }
                    }
                    sampleCount += UInt64(frameCount) * UInt64(channels)
                }
            } catch {
                DispatchQueue.main.async { result(nil) }
                return
            }

            guard sampleCount > 0 else {
                DispatchQueue.main.async { result(nil) }
                return
            }

            let rms = (sumSquares / Double(sampleCount)).squareRoot()
            let rmsDb = rms > 0 ? 20 * log10(rms) : -160.0
            let peakDb = peak > 0 ? 20 * log10(Double(peak)) : -160.0

            DispatchQueue.main.async {
                result(["rmsDbfs": rmsDb, "peakDbfs": peakDb])
            }
        }
    }
}
