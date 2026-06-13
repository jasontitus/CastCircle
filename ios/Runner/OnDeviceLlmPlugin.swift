import Flutter
import UIKit

// The real Gemma runtime is written against mlx-swift-lm's current
// (macro-based) convenience API, but gated behind the GEMMA_RUNTIME compile
// flag so the app builds today. mlx-swift-lm already resolves and
// MLXLLM/MLXLMCommon are linked. To turn inference on:
//   1. Link the MLXHuggingFace product (+ the HuggingFace and Tokenizers
//      modules its macros expand into) to the Runner target.
//   2. Add GEMMA_RUNTIME to the target's Active Compilation Conditions.
//   3. Validate on-device: model load + a prompt round-trip. Use a QAT /
//      PLE-safe Gemma 4 4-bit quant or it emits garbage.
#if GEMMA_RUNTIME
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

/// Flutter platform channel for on-device script structuring with Gemma
/// (MLX). Mirrors `MLXSttPlugin`: talks over `com.lineguide/on_device_llm`,
/// loads weights downloaded to Documents/models/gemma_llm/, and degrades
/// gracefully when the runtime or model isn't present.
class OnDeviceLlmPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var isReady = false
    private var modelPath: String?

    #if GEMMA_RUNTIME
    private var container: ModelContainer?
    #endif

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/on_device_llm",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            Task { await initialize(call: call, result: result) }
        case "generate":
            Task { await generate(call: call, result: result) }
        case "dispose":
            dispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Model management

    private func initialize(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let rawPath = args["modelPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "modelPath required", details: nil))
            return
        }

        // Confine the model path to Documents/models. The path is produced by
        // our own download service, but resolve symlinks + bounds-check it so a
        // malformed or relative path can't escape the models directory. Both
        // sides are symlink-resolved so the iOS /var → /private/var alias on the
        // Documents dir doesn't cause a false rejection.
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        let allowedBase = (((docsDir as NSString)
            .appendingPathComponent("models")) as NSString).resolvingSymlinksInPath
        let path = ((rawPath as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        guard path == allowedBase || path.hasPrefix(allowedBase + "/") else {
            result(FlutterError(code: "INVALID_ARGS",
                                message: "modelPath must be inside the models directory",
                                details: nil))
            return
        }

        // Require the core weights + config before attempting a load.
        let fm = FileManager.default
        let hasConfig = fm.fileExists(atPath: (path as NSString).appendingPathComponent("config.json"))
        let hasWeights = fm.fileExists(atPath: (path as NSString).appendingPathComponent("model.safetensors"))
        guard hasConfig && hasWeights else {
            NSLog("OnDeviceLlm: model files missing at \(path)")
            result(false)
            return
        }
        modelPath = path

        #if GEMMA_RUNTIME
        do {
            NSLog("OnDeviceLlm: loading Gemma from \(path)…")
            let configuration = ModelConfiguration(directory: URL(fileURLWithPath: path))
            container = try await #huggingFaceLoadModelContainer(configuration: configuration)
            isReady = true
            NSLog("OnDeviceLlm: model loaded")
            result(true)
        } catch {
            NSLog("OnDeviceLlm: load failed: \(error.localizedDescription)")
            result(FlutterError(code: "INIT_FAILED", message: error.localizedDescription, details: nil))
        }
        #else
        NSLog("OnDeviceLlm: MLXHuggingFace not linked — Gemma runtime gated off")
        isReady = false
        result(false)
        #endif
    }

    // MARK: - Generation

    private func generate(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let prompt = args["prompt"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "prompt required", details: nil))
            return
        }
        // imagePaths are reserved for the multimodal (VLM) path; the text path
        // ignores them.
        _ = args["imagePaths"] as? [String]

        guard isReady else {
            result(FlutterError(code: "NOT_READY", message: "Model not initialized", details: nil))
            return
        }

        #if GEMMA_RUNTIME
        guard let container = container else {
            result(FlutterError(code: "NOT_READY", message: "No model container", details: nil))
            return
        }
        do {
            // Fresh session per call — script structuring is one-shot, no history.
            let session = ChatSession(
                container,
                generateParameters: GenerateParameters(temperature: 0.0)
            )
            let text = try await session.respond(to: prompt)
            result(text)
        } catch {
            NSLog("OnDeviceLlm: generate failed: \(error.localizedDescription)")
            result(FlutterError(code: "GENERATE_FAILED", message: error.localizedDescription, details: nil))
        }
        #else
        result(FlutterError(
            code: "NOT_IMPLEMENTED",
            message: "Gemma runtime not linked (MLXHuggingFace).",
            details: nil
        ))
        #endif
    }

    private func dispose(result: @escaping FlutterResult) {
        #if GEMMA_RUNTIME
        container = nil
        #endif
        isReady = false
        NSLog("OnDeviceLlm: disposed")
        result(nil)
    }
}
