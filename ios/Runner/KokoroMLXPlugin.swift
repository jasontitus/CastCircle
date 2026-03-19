import Flutter
import UIKit
import AVFoundation

/// Flutter platform channel plugin for on-device Kokoro-MLX TTS.
///
/// Bridges Dart ↔ Swift so the Flutter app can call Kokoro-MLX inference
/// running directly on the device's Apple Silicon GPU/ANE.
class KokoroMLXPlugin: NSObject {
    static let channelName = "com.lineguide/kokoro_mlx"

    private let channel: FlutterMethodChannel
    private let kokoroService = KokoroMLXService()

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(kokoroService.isModelLoaded)

        case "loadModel":
            Task {
                do {
                    try await kokoroService.loadModel()
                    DispatchQueue.main.async { result(true) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "LOAD_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }
            }

        case "synthesize":
            guard let args = call.arguments as? [String: Any],
                  let text = args["text"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'text'", details: nil))
                return
            }
            let voice = args["voice"] as? String ?? "af_heart"
            let speed = args["speed"] as? Double ?? 1.0

            Task {
                // Request background time so synthesis can finish if app is backgrounded
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "KokoroSynth") {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }

                do {
                    let audioPath = try await kokoroService.synthesize(
                        text: text, voice: voice, speed: Float(speed)
                    )
                    DispatchQueue.main.async { result(audioPath) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "SYNTH_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }

                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }

        case "getVoices":
            result(KokoroMLXService.availableVoices)

        case "getModelStatus":
            result([
                "loaded": kokoroService.isModelLoaded,
                "downloaded": kokoroService.isModelDownloaded,
            ])

        case "unloadModel":
            kokoroService.unloadModel()
            result(true)

        case "deleteModel":
            do {
                try kokoroService.deleteModel()
                result(true)
            } catch {
                result(FlutterError(
                    code: "DELETE_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
