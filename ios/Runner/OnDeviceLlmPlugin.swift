import Flutter
import UIKit

// Primary runtime: Apple's built-in on-device LLM (iOS 26 Foundation Models).
// No package, no download — runs on Apple-Intelligence-capable devices.
#if canImport(FoundationModels)
import FoundationModels
#endif

// Secondary runtime (kept for later): Gemma via mlx-swift-lm. Written against
// its macro-based API but gated behind GEMMA_RUNTIME — turning it on also needs
// the MLXHuggingFace + swift-transformers + swift-huggingface modules linked and
// on-device validation. Foundation Models is the path that works today.
#if GEMMA_RUNTIME
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

/// Flutter platform channel for on-device script structuring.
/// Talks over `com.lineguide/on_device_llm`; prefers Apple Foundation Models
/// and falls back to the (gated) MLX Gemma path. Degrades gracefully when no
/// on-device runtime is available.
class OnDeviceLlmPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var isReady = false
    private var useFoundationModels = false
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

    // MARK: - Init

    private func initialize(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        // 1. Prefer Gemma (MLX) when its model is downloaded and the runtime is
        //    compiled in. Any failure falls through to Apple's built-in model.
        #if GEMMA_RUNTIME
        if await loadGemmaIfPossible(call: call) {
            useFoundationModels = false
            isReady = true
            NSLog("OnDeviceLlm: using MLX Gemma")
            result(true)
            return
        }
        #endif

        // 2. Apple's built-in on-device model — no download required.
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            if case .available = availability {
                useFoundationModels = true
                isReady = true
                NSLog("OnDeviceLlm: using Apple Foundation Models")
                result(true)
                return
            }
            NSLog("OnDeviceLlm: Foundation Models unavailable (\(availability))")
        }
        #endif

        NSLog("OnDeviceLlm: no on-device runtime available")
        isReady = false
        result(false)
    }

    #if GEMMA_RUNTIME
    /// Load the downloaded Gemma model. Returns false (so the caller falls back
    /// to Apple's model) when there's no valid model directory or the load fails.
    private func loadGemmaIfPossible(call: FlutterMethodCall) async -> Bool {
        guard let args = call.arguments as? [String: Any],
              let rawPath = args["modelPath"] as? String, !rawPath.isEmpty else {
            return false
        }
        // Confine the model path to Documents/models (symlink-resolved).
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        let allowedBase = (((docsDir as NSString)
            .appendingPathComponent("models")) as NSString).resolvingSymlinksInPath
        let path = ((rawPath as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        guard path == allowedBase || path.hasPrefix(allowedBase + "/") else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: (path as NSString).appendingPathComponent("config.json")),
              fm.fileExists(atPath: (path as NSString).appendingPathComponent("model.safetensors")) else {
            return false
        }
        modelPath = path
        do {
            NSLog("OnDeviceLlm: loading Gemma from \(path)…")
            let configuration = ModelConfiguration(directory: URL(fileURLWithPath: path))
            container = try await #huggingFaceLoadModelContainer(configuration: configuration)
            return true
        } catch {
            NSLog("OnDeviceLlm: Gemma load failed: \(error.localizedDescription)")
            return false
        }
    }
    #endif

    // MARK: - Generate

    private func generate(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        guard let args = call.arguments as? [String: Any],
              let prompt = args["prompt"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "prompt required", details: nil))
            return
        }
        _ = args["imagePaths"] as? [String]  // reserved for the multimodal path

        guard isReady else {
            result(FlutterError(code: "NOT_READY", message: "Model not initialized", details: nil))
            return
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), useFoundationModels {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                result(response.content)
            } catch {
                NSLog("OnDeviceLlm: FM generate failed: \(error.localizedDescription)")
                result(FlutterError(code: "GENERATE_FAILED", message: error.localizedDescription, details: nil))
            }
            return
        }
        #endif

        #if GEMMA_RUNTIME
        guard let container = container else {
            result(FlutterError(code: "NOT_READY", message: "No model container", details: nil))
            return
        }
        do {
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
        result(FlutterError(code: "NOT_IMPLEMENTED", message: "No on-device runtime linked.", details: nil))
        #endif
    }

    private func dispose(result: @escaping FlutterResult) {
        #if GEMMA_RUNTIME
        container = nil
        #endif
        useFoundationModels = false
        isReady = false
        NSLog("OnDeviceLlm: disposed")
        result(nil)
    }
}
