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
            Task {
                let loaded = await kokoroService.isModelLoaded()
                DispatchQueue.main.async { result(loaded) }
            }

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
                // Request background time so an IN-FLIGHT synthesis can finish
                // if the app is backgrounded mid-inference. (New synthesis is
                // refused while backgrounded — GPU work there is a kill; see
                // KokoroMLXService.synthesize.) UIApplication is
                // main-actor-only, so hop for begin/end.
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                await MainActor.run {
                    bgTask = UIApplication.shared.beginBackgroundTask(withName: "KokoroSynth") {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
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

                await MainActor.run {
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                    }
                }
            }

        case "getVoices":
            result(KokoroMLXService.availableVoices)

        case "getModelStatus":
            Task {
                let status = await kokoroService.modelStatus()
                DispatchQueue.main.async {
                    result([
                        "loaded": status.loaded,
                        "downloaded": status.downloaded,
                    ])
                }
            }

        case "unloadModel":
            Task {
                await kokoroService.unloadModel()
                DispatchQueue.main.async { result(true) }
            }

        case "deleteModel":
            Task {
                do {
                    try await kokoroService.deleteModel()
                    DispatchQueue.main.async { result(true) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "DELETE_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
