import Flutter
import UIKit

// The Gemma runtime lives in the mlx-swift-lm package (MLXLLM/MLXLMCommon).
// Until that package is added to the Runner target, this whole block is
// compiled out and the plugin reports "unavailable" — so the app builds and
// ships today, and real inference turns on automatically once the package is
// linked (no code change here). Verify the generate() API against the
// installed mlx-swift-lm version when you enable it.
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLX
#endif

/// Flutter platform channel for on-device script structuring with an MLX LLM
/// (Gemma). Mirrors `MLXSttPlugin`: talks over `com.lineguide/on_device_llm`,
/// loads weights downloaded to Documents/models/gemma_llm/, and degrades
/// gracefully when the runtime or model isn't present.
class OnDeviceLlmPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var isReady = false
    private var modelPath: String?

    #if canImport(MLXLLM)
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

        #if canImport(MLXLLM)
        do {
            NSLog("OnDeviceLlm: loading MLX LLM from \(path)…")
            let configuration = ModelConfiguration(directory: URL(fileURLWithPath: path))
            container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
            isReady = true
            NSLog("OnDeviceLlm: model loaded")
            result(true)
        } catch {
            NSLog("OnDeviceLlm: load failed: \(error.localizedDescription)")
            result(FlutterError(code: "INIT_FAILED", message: error.localizedDescription, details: nil))
        }
        #else
        NSLog("OnDeviceLlm: MLXLLM not linked — add the mlx-swift-lm SPM package to enable Gemma inference")
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
        // imagePaths are reserved for the multimodal (MLXVLM) path; the text
        // path ignores them.
        _ = args["imagePaths"] as? [String]

        guard isReady else {
            result(FlutterError(code: "NOT_READY", message: "Model not initialized", details: nil))
            return
        }

        #if canImport(MLXLLM)
        guard let container = container else {
            result(FlutterError(code: "NOT_READY", message: "No model container", details: nil))
            return
        }
        do {
            let text = try await container.perform { (context) -> String in
                let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
                var output = ""
                let stream = try MLXLMCommon.generate(
                    input: input,
                    parameters: GenerateParameters(maxTokens: 4096, temperature: 0.0),
                    context: context
                )
                for await item in stream {
                    if case .chunk(let piece) = item { output += piece }
                }
                return output
            }
            result(text)
        } catch {
            NSLog("OnDeviceLlm: generate failed: \(error.localizedDescription)")
            result(FlutterError(code: "GENERATE_FAILED", message: error.localizedDescription, details: nil))
        }
        #else
        result(FlutterError(
            code: "NOT_IMPLEMENTED",
            message: "Gemma runtime not bundled. Add the mlx-swift-lm SPM package.",
            details: nil
        ))
        #endif
    }

    private func dispose(result: @escaping FlutterResult) {
        #if canImport(MLXLLM)
        container = nil
        #endif
        isReady = false
        NSLog("OnDeviceLlm: disposed")
        result(nil)
    }
}
