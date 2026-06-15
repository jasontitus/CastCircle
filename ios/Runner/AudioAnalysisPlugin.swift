import Flutter
import AVFoundation

/// Native plugin that measures the loudness of a recorded audio file so the
/// Dart side can normalize playback volume across cast recordings.
///
/// Reads the file's PCM via AVAudioFile and returns peak/RMS in dBFS. Line
/// recordings are short, so reading the whole buffer is cheap; results are
/// cached on the Dart side keyed by path.
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
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: frameCount),
                  (try? file.read(into: buffer)) != nil,
                  let channelData = buffer.floatChannelData else {
                DispatchQueue.main.async { result(nil) }
                return
            }

            let channels = Int(format.channelCount)
            let n = Int(buffer.frameLength)
            if n == 0 {
                DispatchQueue.main.async { result(nil) }
                return
            }

            var sumSquares: Double = 0
            var peak: Float = 0
            for c in 0..<channels {
                let samples = channelData[c]
                for i in 0..<n {
                    let s = samples[i]
                    sumSquares += Double(s) * Double(s)
                    let a = abs(s)
                    if a > peak { peak = a }
                }
            }

            let total = Double(n * channels)
            let rms = total > 0 ? (sumSquares / total).squareRoot() : 0
            let rmsDb = rms > 0 ? 20 * log10(rms) : -160.0
            let peakDb = peak > 0 ? 20 * log10(Double(peak)) : -160.0

            DispatchQueue.main.async {
                result(["rmsDbfs": rmsDb, "peakDbfs": peakDb])
            }
        }
    }
}
