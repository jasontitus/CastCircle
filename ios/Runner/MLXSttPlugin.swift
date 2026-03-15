import Flutter
import UIKit
import AVFoundation
import ParakeetSTT
import MLX

/// Flutter platform channel plugin for on-device speech-to-text using
/// MLX Parakeet (real neural model inference on Apple Silicon).
class MLXSttPlugin: NSObject, FlutterStreamHandler {
    private let channel: FlutterMethodChannel
    private let streamChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    private var isModelLoaded = false

    /// The loaded Parakeet STT model.
    private var sttModel: ParakeetModel? = nil
    private static let modelId = "mlx-community/parakeet-tdt-0.6b-v3"

    /// Model directory — downloaded model files live here.
    private static var modelDir: URL? {
        // Check Documents/models/parakeet_stt/ (downloaded via BackgroundDownloadPlugin)
        if let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let appModelDir = docsDir
                .appendingPathComponent("models")
                .appendingPathComponent("parakeet_stt")
            let configPath = appModelDir.appendingPathComponent("config.json")
            let modelPath = appModelDir.appendingPathComponent("model.safetensors")
            if FileManager.default.fileExists(atPath: configPath.path) &&
               FileManager.default.fileExists(atPath: modelPath.path) {
                NSLog("MLXStt: Found model at \(appModelDir.path)")
                return appModelDir
            }
        }

        // Fallback: HuggingFace cache (if downloaded externally)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let hfDir = cacheDir
            .appendingPathComponent("huggingface/hub")
            .appendingPathComponent("models--mlx-community--parakeet-tdt-0.6b-v3")
        if FileManager.default.fileExists(atPath: hfDir.path) {
            let snapshotsDir = hfDir.appendingPathComponent("snapshots")
            if let snapshots = try? FileManager.default.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil),
               let firstSnapshot = snapshots.first {
                return firstSnapshot
            }
            return hfDir
        }

        return nil
    }

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/mlx_stt",
            binaryMessenger: messenger
        )
        streamChannel = FlutterEventChannel(
            name: "com.lineguide/mlx_stt_stream",
            binaryMessenger: messenger
        )
        super.init()

        channel.setMethodCallHandler(handle)
        streamChannel.setStreamHandler(self)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            Task {
                await initialize(result: result)
            }
        case "transcribe":
            Task {
                await transcribe(call: call, result: result)
            }
        case "transcribeStreaming":
            Task {
                await transcribeStreaming(call: call, result: result)
            }
        case "loadAdapter":
            result(true)
        case "unloadAdapter":
            result(true)
        case "downloadModel":
            result(FlutterError(
                code: "NOT_IMPLEMENTED",
                message: "Use BackgroundDownloadPlugin to download model files.",
                details: nil
            ))
        case "isModelDownloaded":
            result(Self.modelDir != nil)
        case "isReady":
            result(isModelLoaded)
        case "dispose":
            dispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Model Management

    private func initialize(result: @escaping FlutterResult) async {
        if isModelLoaded && sttModel != nil {
            result(true)
            return
        }

        guard let modelDir = Self.modelDir else {
            NSLog("MLXStt: Model not downloaded yet")
            result(FlutterError(
                code: "MODEL_NOT_FOUND",
                message: "Parakeet model not downloaded. Download model files first.",
                details: nil
            ))
            return
        }

        do {
            NSLog("MLXStt: Loading Parakeet model from \(modelDir.path)...")
            sttModel = try ParakeetModel.fromDirectory(modelDir)
            isModelLoaded = true
            NSLog("MLXStt: Parakeet model loaded successfully")
            result(true)
        } catch {
            NSLog("MLXStt: Failed to load Parakeet model: \(error.localizedDescription)")
            result(FlutterError(
                code: "INIT_FAILED",
                message: "Failed to load Parakeet model: \(error.localizedDescription)",
                details: nil
            ))
        }
    }

    // MARK: - Transcription

    private func transcribe(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let audioPath = args["audioPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "audioPath required", details: nil))
            return
        }

        guard isModelLoaded, let model = sttModel else {
            result(FlutterError(code: "NOT_READY", message: "Model not initialized", details: nil))
            return
        }

        let audioURL = URL(fileURLWithPath: audioPath)

        guard FileManager.default.fileExists(atPath: audioPath) else {
            result(FlutterError(code: "FILE_NOT_FOUND", message: "Audio file not found", details: nil))
            return
        }

        do {
            let (_, audioData) = try loadAudioArray(from: audioURL)
            let output = model.generate(audio: audioData)
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("MLXStt: Transcribed (\(text.prefix(60))...)")
            result(text)
        } catch {
            NSLog("MLXStt: Transcription failed: \(error.localizedDescription)")
            result(FlutterError(
                code: "TRANSCRIBE_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    /// Streaming transcription — sends partial results via EventChannel as
    /// Parakeet processes audio in chunks. Returns final text via method result.
    private func transcribeStreaming(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let audioPath = args["audioPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "audioPath required", details: nil))
            return
        }

        guard isModelLoaded, let model = sttModel else {
            result(FlutterError(code: "NOT_READY", message: "Model not initialized", details: nil))
            return
        }

        let audioURL = URL(fileURLWithPath: audioPath)

        guard FileManager.default.fileExists(atPath: audioPath) else {
            result(FlutterError(code: "FILE_NOT_FOUND", message: "Audio file not found", details: nil))
            return
        }

        do {
            let (_, audioData) = try loadAudioArray(from: audioURL)

            // Use streaming generation — emits tokens progressively
            let params = STTGenerateParameters(
                chunkDuration: 5.0  // Process in 5-second chunks for progressive results
            )

            var fullText = ""
            let stream = model.generateStream(audio: audioData, generationParameters: params)

            for try await event in stream {
                switch event {
                case .token(let token):
                    fullText += token
                    // Send partial text to Dart via EventChannel
                    DispatchQueue.main.async { [weak self] in
                        self?.eventSink?(["type": "partial", "text": fullText])
                    }

                case .result(let output):
                    fullText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async { [weak self] in
                        self?.eventSink?(["type": "final", "text": fullText])
                    }

                case .info:
                    break
                }
            }

            NSLog("MLXStt: Streamed transcription (\(fullText.prefix(60))...)")
            result(fullText)
        } catch {
            NSLog("MLXStt: Streaming transcription failed: \(error.localizedDescription)")
            result(FlutterError(
                code: "TRANSCRIBE_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    // MARK: - Cleanup

    private func dispose(result: @escaping FlutterResult) {
        sttModel = nil
        isModelLoaded = false
        NSLog("MLXStt: Disposed")
        result(nil)
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
