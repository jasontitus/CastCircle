import Flutter
import AVFoundation
import Accelerate

/// Native plugin that measures the loudness of a recorded audio file so the
/// Dart side can normalize playback volume across cast recordings.
///
/// Decodes through one reusable fixed-size PCM buffer, so peak memory does
/// not grow with recording duration. Results are cached on the Dart side.
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
            let measurement = Self.measureLoudness(at: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                guard let measurement = measurement else {
                    result(nil)
                    return
                }
                result([
                    "rmsDbfs": measurement.rmsDbfs,
                    "peakDbfs": measurement.peakDbfs,
                ])
            }
        }
    }

    struct LoudnessMeasurement {
        let rmsDbfs: Double
        let peakDbfs: Double
    }

    /// Streams decoded PCM through a bounded buffer. Internal for focused
    /// Runner tests; the platform-channel contract remains the dictionary
    /// returned by `loudness`.
    static func measureLoudness(at url: URL) -> LoudnessMeasurement? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let format = file.processingFormat
        let chunkFrames: AVAudioFrameCount = 32_768
        guard format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: chunkFrames
              ) else {
            return nil
        }

        let channels = Int(format.channelCount)
        var sampleCount: UInt64 = 0
        var sumSquares = 0.0
        var peak: Float = 0

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let framesToRead = AVAudioFrameCount(min(
                AVAudioFramePosition(chunkFrames),
                remaining
            ))

            do {
                try file.read(into: buffer, frameCount: framesToRead)
            } catch {
                return nil
            }

            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0, let channelData = buffer.floatChannelData else {
                break
            }

            for channel in 0..<channels {
                var chunkSum: Float = 0
                var chunkPeak: Float = 0
                vDSP_svesq(
                    channelData[channel],
                    1,
                    &chunkSum,
                    vDSP_Length(framesRead)
                )
                vDSP_maxmgv(
                    channelData[channel],
                    1,
                    &chunkPeak,
                    vDSP_Length(framesRead)
                )
                sumSquares += Double(chunkSum)
                peak = max(peak, chunkPeak)
            }
            sampleCount += UInt64(framesRead * channels)
        }

        guard sampleCount > 0 else { return nil }
        let rms = (sumSquares / Double(sampleCount)).squareRoot()
        return LoudnessMeasurement(
            rmsDbfs: rms > 0 ? 20 * log10(rms) : -160.0,
            peakDbfs: peak > 0 ? 20 * log10(Double(peak)) : -160.0
        )
    }
}
