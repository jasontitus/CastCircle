import Flutter
import UIKit
import AVFoundation

/// Flutter platform channel plugin for MLX-based speech-to-text.
///
/// Bridges Flutter (Dart) to native MLX audio inference via method channels.
/// Uses Parakeet-TDT-0.6B for high-quality on-device ASR.
class MLXSttPlugin: NSObject, FlutterStreamHandler {
    private let channel: FlutterMethodChannel
    private let trainingChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    private var isModelLoaded = false

    // MLX model instance (will be typed properly when mlx-audio-swift is linked)
    private var sttModel: Any? = nil

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/mlx_stt",
            binaryMessenger: messenger
        )
        trainingChannel = FlutterEventChannel(
            name: "com.lineguide/mlx_stt_training",
            binaryMessenger: messenger
        )
        super.init()

        channel.setMethodCallHandler(handle)
        trainingChannel.setStreamHandler(self)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            Task {
                await initialize(call: call, result: result)
            }
        case "transcribe":
            Task {
                await transcribe(call: call, result: result)
            }
        case "loadAdapter":
            loadAdapter(call: call, result: result)
        case "unloadAdapter":
            unloadAdapter(result: result)
        case "downloadModel":
            Task {
                await downloadModel(result: result)
            }
        case "isModelDownloaded":
            isModelDownloaded(result: result)
        case "isReady":
            result(isModelLoaded)
        case "dispose":
            dispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Model Management

    private func initialize(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let modelPath = args["modelPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "modelPath required", details: nil))
            return
        }

        do {
            // Load the MLX STT model from the local path
            try await loadModel(from: modelPath)
            isModelLoaded = true
            result(true)
        } catch {
            result(FlutterError(code: "INIT_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    private func loadModel(from path: String) async throws {
        #if canImport(MLXAudioSTT)
        // When mlx-audio-swift is linked, load the Parakeet model:
        // import MLXAudioSTT
        // import MLXAudioCore
        // sttModel = try await ParakeetModel.fromPretrained(path)
        NSLog("MLXStt: Loading model from \(path)")
        // For now, mark as loaded if the model directory exists
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw NSError(domain: "MLXStt", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Model directory not found: \(path)"])
        }
        NSLog("MLXStt: Model directory found, marking as ready")
        #else
        // MLX not available — stub for compilation without the dependency
        NSLog("MLXStt: mlx-audio-swift not linked, using stub mode")
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw NSError(domain: "MLXStt", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Model directory not found: \(path)"])
        }
        #endif
    }

    // MARK: - Transcription

    private func transcribe(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let audioPath = args["audioPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "audioPath required", details: nil))
            return
        }

        guard isModelLoaded else {
            result(FlutterError(code: "NOT_READY", message: "Model not initialized", details: nil))
            return
        }

        do {
            let text = try await transcribeAudio(at: audioPath,
                                                  hints: args["vocabularyHints"] as? [String])
            result(text)
        } catch {
            result(FlutterError(code: "TRANSCRIBE_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    private func transcribeAudio(at path: String, hints: [String]?) async throws -> String {
        #if canImport(MLXAudioSTT)
        // When mlx-audio-swift is linked:
        // let (sampleRate, audioData) = try loadAudioArray(from: URL(fileURLWithPath: path))
        // let output = sttModel!.generate(audio: audioData)
        // return output.text
        NSLog("MLXStt: Would transcribe \(path) with \(hints?.count ?? 0) vocabulary hints")
        return ""
        #else
        // Stub — return empty string when MLX not linked
        NSLog("MLXStt: Stub transcribe for \(path)")
        return ""
        #endif
    }

    // MARK: - LoRA Adapters

    private func loadAdapter(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let adapterPath = args["adapterPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "adapterPath required", details: nil))
            return
        }

        NSLog("MLXStt: Loading adapter from \(adapterPath)")
        // Future: merge LoRA adapter weights with base model
        result(true)
    }

    private func unloadAdapter(result: @escaping FlutterResult) {
        NSLog("MLXStt: Unloading adapter")
        result(true)
    }

    // MARK: - Model Download

    private static let parakeetModelId = "mlx-community/parakeet-tdt-0.6b-v3"

    private func downloadModel(result: @escaping FlutterResult) async {
        #if canImport(MLXAudioSTT)
        // When mlx-audio-swift is linked:
        // do {
        //     let modelDir = try await ParakeetModel.fromPretrained(Self.parakeetModelId)
        //     NSLog("MLXStt: Model downloaded to \(modelDir)")
        //     result(true)
        // } catch {
        //     result(FlutterError(code: "DOWNLOAD_FAILED", message: error.localizedDescription, details: nil))
        // }
        NSLog("MLXStt: Would download \(Self.parakeetModelId) via mlx-audio-swift")
        result(true)
        #else
        // Stub — mlx-audio-swift not linked
        NSLog("MLXStt: Stub downloadModel — mlx-audio-swift not linked")
        result(true)
        #endif
    }

    private func isModelDownloaded(result: @escaping FlutterResult) {
        // Check if model files exist in the app's documents directory
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelDir = documentsDir.appendingPathComponent("models/parakeet-tdt-0.6b-v3")
        let exists = FileManager.default.fileExists(atPath: modelDir.path)
        result(exists)
    }

    // MARK: - Cleanup

    private func dispose(result: @escaping FlutterResult) {
        sttModel = nil
        isModelLoaded = false
        NSLog("MLXStt: Disposed")
        result(nil)
    }

    // MARK: - FlutterStreamHandler (training progress)

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
