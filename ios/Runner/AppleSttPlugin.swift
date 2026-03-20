import Flutter
import UIKit
import Speech
import AVFoundation

/// Native Apple SFSpeechRecognizer plugin with contextualStrings support.
/// Provides real-time streaming STT with vocabulary hinting.
class AppleSttPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var authorized = false

    // Concurrent audio recording during STT
    private var audioFile: AVAudioFile?
    private var recordingStartTime: Date?
    private var recordingPath: String?
    private var tapFormat: AVAudioFormat? // cached from installTap

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/apple_stt",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            let args = call.arguments as? [String: Any] ?? [:]
            let locale = args["locale"] as? String ?? "en-US"
            initialize(locale: locale, result: result)
        case "listen":
            let args = call.arguments as? [String: Any] ?? [:]
            let hints = args["contextualStrings"] as? [String] ?? []
            let onDevice = args["onDevice"] as? Bool ?? false
            let locale = args["locale"] as? String
            listen(contextualStrings: hints, onDevice: onDevice, locale: locale, result: result)
        case "stop":
            stopListening(result: result)
        case "startRecording":
            let args = call.arguments as? [String: Any] ?? [:]
            let path = args["path"] as? String ?? ""
            startRecording(path: path, result: result)
        case "stopRecording":
            stopRecording(result: result)
        case "isAvailable":
            result(recognizer?.isAvailable ?? false)
        case "dispose":
            stopListening(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func initialize(locale: String, result: @escaping FlutterResult) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        NSLog("AppleStt: Initialized with locale: \(locale)")

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.authorized = true
                    NSLog("AppleStt: Authorized")
                    result(true)
                case .denied:
                    NSLog("AppleStt: Denied")
                    result(FlutterError(code: "DENIED", message: "Speech recognition denied", details: nil))
                case .restricted:
                    NSLog("AppleStt: Restricted")
                    result(FlutterError(code: "RESTRICTED", message: "Speech recognition restricted", details: nil))
                case .notDetermined:
                    NSLog("AppleStt: Not determined")
                    result(false)
                @unknown default:
                    result(false)
                }
            }
        }
    }

    private func listen(contextualStrings: [String], onDevice: Bool, locale: String?, result: @escaping FlutterResult) {
        // Always fully stop any previous session first to prevent
        // "tap already installed" crash from rapid jump-backs
        stopCurrentSession()

        // If a different locale is requested, recreate the recognizer
        if let locale = locale {
            let newRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            if newRecognizer != nil {
                recognizer = newRecognizer
                NSLog("AppleStt: Switched locale to \(locale)")
            }
        }

        guard authorized, let recognizer = recognizer, recognizer.isAvailable else {
            result(FlutterError(code: "NOT_READY", message: "Speech recognizer not available", details: nil))
            return
        }

        // Stop any existing session
        stopCurrentSession()

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .default, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("AppleStt: Audio session error: \(error)")
            result(FlutterError(code: "AUDIO_ERROR", message: error.localizedDescription, details: nil))
            return
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            result(FlutterError(code: "REQUEST_ERROR", message: "Could not create request", details: nil))
            return
        }

        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        // Allow server-side recognition for better quality.
        // On-device is much worse — only use it if explicitly requested
        // AND on-device model is available.
        if onDevice {
            if recognizer.supportsOnDeviceRecognition {
                // Prefer on-device but don't require it — fall back to server
                // if on-device can't handle the input
                request.requiresOnDeviceRecognition = false
            }
        }

        // Vocabulary hints — the key feature for script line matching
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
            NSLog("AppleStt: Set \(contextualStrings.count) contextual strings: \(contextualStrings.prefix(5))")
        }

        // Auto-punctuation (iOS 16+)
        if #available(iOS 16.0, *) {
            request.addsPunctuation = false // Don't add punctuation for line matching
        }

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] recognitionResult, error in
            guard let self = self else { return }

            if let recognitionResult = recognitionResult {
                let text = recognitionResult.bestTranscription.formattedString
                let isFinal = recognitionResult.isFinal

                // Send result back to Dart
                DispatchQueue.main.async {
                    self.channel.invokeMethod("onResult", arguments: [
                        "text": text,
                        "isFinal": isFinal,
                    ])
                }

                if isFinal {
                    self.stopCurrentSession()
                    DispatchQueue.main.async {
                        self.channel.invokeMethod("onDone", arguments: nil)
                    }
                }
            }

            if let error = error {
                NSLog("AppleStt: Recognition error: \(error.localizedDescription)")
                self.stopCurrentSession()
                DispatchQueue.main.async {
                    self.channel.invokeMethod("onError", arguments: error.localizedDescription)
                    self.channel.invokeMethod("onDone", arguments: nil)
                }
            }
        }

        // Install audio tap and start engine
        let inputNode = audioEngine.inputNode

        // Fully stop and remove any existing tap — belt and suspenders
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        inputNode.removeTap(onBus: 0)

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        tapFormat = recordingFormat // cache for startRecording

        // installTap throws an ObjC NSException (not a Swift error) if a tap
        // is already installed. Wrap in ObjC exception catcher.
        var tapInstalled = false
        ObjCExceptionCatcher.try({
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                // Concurrent recording: write same audio buffers to file
                if let file = self?.audioFile {
                    do {
                        try file.write(from: buffer)
                    } catch {
                        NSLog("AppleStt: audioFile.write FAILED: \(error)")
                        self?.audioFile = nil // stop trying after first failure
                    }
                }
            }
            tapInstalled = true
        }, catch: { exception in
            NSLog("AppleStt: installTap exception: \(String(describing: exception))")
        })

        guard tapInstalled else {
            NSLog("AppleStt: Failed to install tap, aborting listen")
            stopCurrentSession()
            result(FlutterError(code: "TAP_FAILED", message: "Could not install audio tap", details: nil))
            return
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            NSLog("AppleStt: Listening started")
            result(true)
        } catch {
            NSLog("AppleStt: Engine start error: \(error)")
            stopCurrentSession()
            result(FlutterError(code: "ENGINE_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func stopListening(result: @escaping FlutterResult) {
        stopCurrentSession()
        result(nil)
    }

    // MARK: - Concurrent Recording

    /// Start recording audio to a file alongside STT.
    /// The audio is captured from the same AVAudioEngine tap.
    private func startRecording(path: String, result: @escaping FlutterResult) {
        recordingPath = path
        recordingStartTime = Date()

        guard let format = tapFormat else {
            NSLog("AppleStt: startRecording FAILED — no tap format (engine not running?)")
            result(false)
            return
        }

        // Write PCM in native tap format (.caf) — convert to AAC on stop.
        // AVAudioFile.write() only works reliably with PCM output formats.
        let cafPath = path + ".caf"

        do {
            audioFile = try AVAudioFile(
                forWriting: URL(fileURLWithPath: cafPath),
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            NSLog("AppleStt: Recording started → \(cafPath) (PCM \(format.sampleRate)Hz \(format.channelCount)ch)")
            result(true)
        } catch {
            NSLog("AppleStt: Failed to create audio file: \(error)")
            audioFile = nil
            recordingPath = nil
            result(FlutterError(code: "RECORD_ERROR",
                                message: error.localizedDescription, details: nil))
        }
    }

    /// Stop recording, convert CAF→M4A, return {path, durationMs}.
    private func stopRecording(result: @escaping FlutterResult) {
        guard let _ = audioFile, let destPath = recordingPath else {
            result(nil)
            return
        }

        let durationMs = Int((Date().timeIntervalSince(recordingStartTime ?? Date())) * 1000)
        let cafPath = destPath + ".caf"

        // Close the PCM file
        audioFile = nil
        recordingStartTime = nil
        recordingPath = nil

        let cafSize = (try? FileManager.default.attributesOfItem(atPath: cafPath)[.size] as? Int) ?? 0
        NSLog("AppleStt: PCM captured → \(cafPath) (\(durationMs)ms, \(cafSize / 1024)KB)")

        if cafSize < 100 {
            NSLog("AppleStt: PCM file too small, discarding")
            try? FileManager.default.removeItem(atPath: cafPath)
            result(["path": destPath, "durationMs": durationMs])
            return
        }

        // Convert PCM CAF → AAC M4A
        DispatchQueue.global(qos: .userInitiated).async {
            let cafUrl = URL(fileURLWithPath: cafPath)
            let destUrl = URL(fileURLWithPath: destPath)
            try? FileManager.default.removeItem(at: destUrl)

            guard let exportSession = AVAssetExportSession(
                asset: AVAsset(url: cafUrl),
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                NSLog("AppleStt: No export session available, keeping CAF")
                try? FileManager.default.moveItem(at: cafUrl, to: destUrl)
                DispatchQueue.main.async {
                    result(["path": destPath, "durationMs": durationMs])
                }
                return
            }

            exportSession.outputURL = destUrl
            exportSession.outputFileType = .m4a

            exportSession.exportAsynchronously {
                try? FileManager.default.removeItem(at: cafUrl)

                let m4aSize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int) ?? 0
                DispatchQueue.main.async {
                    if exportSession.status == .completed {
                        NSLog("AppleStt: Converted → \(destPath) (\(m4aSize / 1024)KB M4A)")
                    } else {
                        NSLog("AppleStt: Export failed: \(exportSession.error?.localizedDescription ?? "unknown")")
                    }
                    result(["path": destPath, "durationMs": durationMs])
                }
            }
        }
    }

    private func stopCurrentSession() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        // Do NOT deactivate the audio session here. TTS reconfigures it to
        // .playback in KokoroMLXService.synthesize(). Deferred deactivation
        // caused a race condition: it would fire ~2s after STT stopped, killing
        // the audio session right as TTS playback was starting.
    }
}
