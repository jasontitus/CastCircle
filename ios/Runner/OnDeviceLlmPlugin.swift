import Flutter
import UIKit

// Primary runtime: Apple's built-in on-device LLM (iOS 26 Foundation Models).
// No package, no download — runs on Apple-Intelligence-capable devices.
#if canImport(FoundationModels)
import FoundationModels
#endif

// Gemma via mlx-swift-lm, behind GEMMA_RUNTIME (link MLXHuggingFace +
// HuggingFace + Tokenizers and set the flag to enable). The heavy model load
// is deferred to the first generate() so app startup never pays for it.
#if GEMMA_RUNTIME
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

/// Flutter platform channel for on-device script structuring.
/// Talks over `com.lineguide/on_device_llm`; prefers Gemma (lazy-loaded) and
/// falls back to Apple's built-in model. `initialize` returns a status map
/// `{ ready, runtime, error }` so the Dart side can log what's going on.
class OnDeviceLlmPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var isReady = false
    private var useFoundationModels = false
    private var gemmaModelPath: String?

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

    /// Log to both the system log and the Flutter debug log (via the channel),
    /// so progress through a long model load/generate is visible in-app.
    private func report(_ message: String) {
        NSLog("OnDeviceLlm: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("onLog", arguments: message)
        }
    }

    // MARK: - Init (cheap — no model load here)

    private func initialize(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        // 1. Gemma: just confirm the model files are present (no load yet).
        #if GEMMA_RUNTIME
        if let path = validatedModelDir(call: call) {
            gemmaModelPath = path
            useFoundationModels = false
            isReady = true
            NSLog("OnDeviceLlm: Gemma model present (loads on first use)")
            result(["ready": true, "runtime": "gemma", "error": ""])
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
                result(["ready": true, "runtime": "foundation", "error": ""])
                return
            }
            NSLog("OnDeviceLlm: Foundation Models unavailable (\(availability))")
            isReady = false
            result(["ready": false, "runtime": "none",
                    "error": "no gemma model; foundationModels: \(availability)"])
            return
        }
        #endif

        isReady = false
        result(["ready": false, "runtime": "none", "error": "no on-device runtime"])
    }

    /// Validate the model directory and confirm core files exist (cheap, no I/O
    /// beyond `fileExists`). Returns the resolved path or nil.
    private func validatedModelDir(call: FlutterMethodCall) -> String? {
        guard let args = call.arguments as? [String: Any],
              let rawPath = args["modelPath"] as? String, !rawPath.isEmpty else {
            return nil
        }
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        let allowedBase = (((docsDir as NSString)
            .appendingPathComponent("models")) as NSString).resolvingSymlinksInPath
        let path = ((rawPath as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        guard path == allowedBase || path.hasPrefix(allowedBase + "/") else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: (path as NSString).appendingPathComponent("config.json")),
              fm.fileExists(atPath: (path as NSString).appendingPathComponent("model.safetensors")) else {
            return nil
        }
        return path
    }

    // MARK: - Generate (Gemma loads lazily here)

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

        #if GEMMA_RUNTIME
        if !useFoundationModels, let path = gemmaModelPath {
            do {
                if container == nil {
                    report("gemma: loading model weights (≈700 MB)…")
                    // Gemma signals end-of-turn with <end_of_turn>, which isn't
                    // the model's <eos> — without this the generator runs past it
                    // and rambles. Register it as an extra stop token.
                    let configuration = ModelConfiguration(
                        directory: URL(fileURLWithPath: path),
                        extraEOSTokens: ["<end_of_turn>"]
                    )
                    container = try await #huggingFaceLoadModelContainer(configuration: configuration)
                    report("gemma: model loaded")
                }
                guard let container = container else {
                    result(FlutterError(code: "NOT_READY", message: "No model container", details: nil))
                    return
                }
                report("gemma: generating…")
                // Bound generation (was unbounded → could run forever) and
                // stream so progress is visible token-by-token.
                let session = ChatSession(
                    container,
                    generateParameters: GenerateParameters(maxTokens: 800, temperature: 0.0)
                )
                var text = ""
                var tokens = 0
                for try await chunk in session.streamResponse(to: prompt) {
                    text += chunk
                    tokens += 1
                    if tokens % 8 == 0 {
                        report("gemma: generating… \(tokens) tokens")
                    }
                }
                report("gemma: done — \(tokens) tokens, \(text.count) chars")
                result(text)
            } catch {
                report("gemma: failed — \(error.localizedDescription)")
                result(FlutterError(code: "GENERATE_FAILED", message: error.localizedDescription, details: nil))
            }
            return
        }
        #endif

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

        result(FlutterError(code: "NOT_IMPLEMENTED", message: "No on-device runtime linked.", details: nil))
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
