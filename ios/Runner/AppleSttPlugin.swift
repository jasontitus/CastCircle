#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
import UIKit
#endif
import Speech
import AVFoundation
import Accelerate

/// Native Apple SFSpeechRecognizer plugin with contextualStrings support.
/// Provides real-time streaming STT with vocabulary hinting.
///
/// Cross-platform: compiles for both iOS and macOS. The recognizer
/// (SFSpeechRecognizer), AVAudioEngine mic tap, and AVAssetExportSession
/// conversion are all available on macOS; the iOS-only AVAudioSession
/// configuration and ObjC exception catcher are guarded with `#if os(iOS)`.
class AppleSttPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let recognitionRequestLock = NSLock()
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var authorized = false
    /// Main-queue generation token. Late callbacks from a stopped recognizer
    /// must not tear down a newer session.
    private var sessionGeneration: UInt = 0
    private var hasInstalledTap = false

    // Concurrent audio recording during STT
    /// The file itself is queue-confined. The small buffer-pool lock only
    /// protects render-thread buffer ownership and the recording-active flag;
    /// disk I/O never runs while that lock is held.
    private var audioFile: AVAudioFile?
    private let audioFileQueue = DispatchQueue(label: "com.lineguide.stt.audiofile")
    private let recordingBufferLock = NSLock()
    private var recordingActive = false
    private var recordingBufferPool: [AVAudioPCMBuffer] = []
    private static let tapBufferSize: AVAudioFrameCount = 4096
    private static let recordingBufferPoolSize = 8

    private var recordingStartTime: Date?
    private var recordingPath: String?
    private var recordingCafPath: String?
    private var tapFormat: AVAudioFormat?

    /// Copy into a preallocated buffer. The tap's source buffer is reused as
    /// soon as its callback returns.
    private static func copyBuffer(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        guard destination.frameCapacity >= source.frameLength else { return false }
        destination.frameLength = source.frameLength
        if let src = source.floatChannelData, let dst = destination.floatChannelData {
            for channel in 0..<Int(source.format.channelCount) {
                dst[channel].update(from: src[channel], count: Int(source.frameLength))
            }
            return true
        }
        if let src = source.int16ChannelData, let dst = destination.int16ChannelData {
            for channel in 0..<Int(source.format.channelCount) {
                dst[channel].update(from: src[channel], count: Int(source.frameLength))
            }
            return true
        }
        return false
    }

    private func appendToRecognitionRequest(
        _ buffer: AVAudioPCMBuffer,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        recognitionRequestLock.lock()
        if recognitionRequest === request {
            request.append(buffer)
        }
        recognitionRequestLock.unlock()
    }

    private func enqueueRecordingBuffer(_ source: AVAudioPCMBuffer) {
        recordingBufferLock.lock()
        guard recordingActive, let destination = recordingBufferPool.popLast() else {
            recordingBufferLock.unlock()
            return
        }
        guard Self.copyBuffer(source, into: destination) else {
            recordingBufferPool.append(destination)
            recordingBufferLock.unlock()
            return
        }

        // Enqueue while holding the ownership lock. stopRecording first takes
        // this lock to disable capture, then drains audioFileQueue, so no tap
        // write can arrive after the drain.
        audioFileQueue.async { [weak self] in
            guard let self else { return }
            if let file = self.audioFile {
                do {
                    try file.write(from: destination)
                } catch {
                    NSLog("AppleStt: audioFile.write FAILED: \(error)")
                    self.audioFile = nil
                    self.recordingBufferLock.lock()
                    self.recordingActive = false
                    self.recordingBufferLock.unlock()
                }
            }
            self.recordingBufferLock.lock()
            self.recordingBufferPool.append(destination)
            self.recordingBufferLock.unlock()
        }
        recordingBufferLock.unlock()
    }

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/apple_stt",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)

        #if os(iOS)
        // Phone calls / Siri / alarms interrupt the shared session and kill
        // the input engine; unplugging headphones kills the input route.
        // Surface both to Dart so rehearsal can pause instead of stranding
        // (the state machine used to wait forever for a playback completion
        // that never fires).
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
        #endif
    }

    #if os(iOS)
    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        let began = type == .began
        var shouldResume = false
        if !began, let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
            shouldResume = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                .contains(.shouldResume)
        }
        NSLog("AppleStt: audio interruption \(began ? "began" : "ended") shouldResume=\(shouldResume)")
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("onAudioInterruption", arguments: [
                "began": began,
                "shouldResume": shouldResume,
            ])
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
              reason == .oldDeviceUnavailable else { return } // headphones unplugged
        NSLog("AppleStt: audio route lost (old device unavailable)")
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("onAudioRouteLost", arguments: nil)
        }
    }
    #endif

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            let args = call.arguments as? [String: Any] ?? [:]
            let locale = args["locale"] as? String ?? "en-US"
            initialize(locale: locale, result: result)
        case "listen":
            let args = call.arguments as? [String: Any] ?? [:]
            guard let sessionId = args["sessionId"] as? Int else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing sessionId",
                    details: nil
                ))
                return
            }
            let hints = args["contextualStrings"] as? [String] ?? []
            let onDevice = args["onDevice"] as? Bool ?? false
            let locale = args["locale"] as? String
            listen(
                contextualStrings: hints,
                onDevice: onDevice,
                locale: locale,
                sessionId: sessionId,
                result: result
            )
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

        #if os(macOS)
        // macOS gates mic access separately from speech recognition. Trigger the
        // microphone TCC prompt now (NSMicrophoneUsageDescription) so the
        // AVAudioEngine input tap isn't fed silence on first listen.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("AppleStt: macOS mic access granted=\(granted)")
        }
        #endif

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

    private func listen(
        contextualStrings: [String],
        onDevice: Bool,
        locale: String?,
        sessionId: Int,
        result: @escaping FlutterResult
    ) {
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
        guard !onDevice || recognizer.supportsOnDeviceRecognition else {
            result(FlutterError(
                code: "ON_DEVICE_UNAVAILABLE",
                message: "On-device speech recognition is not available",
                details: nil
            ))
            return
        }

        // Configure audio session (iOS only — macOS has no AVAudioSession;
        // AVAudioEngine uses the default input device directly).
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .default, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("AppleStt: Audio session error: \(error)")
            result(FlutterError(code: "AUDIO_ERROR", message: error.localizedDescription, details: nil))
            return
        }
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()

        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        // When Dart requires offline recognition, fail above if the selected
        // recognizer cannot honor it rather than silently sending audio to a
        // server.
        request.requiresOnDeviceRecognition = onDevice

        // Vocabulary hints — the key feature for script line matching
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
            NSLog("AppleStt: Set \(contextualStrings.count) contextual strings")
        }

        // Auto-punctuation (iOS 16+ / macOS 13+)
        if #available(iOS 16.0, macOS 13.0, *) {
            request.addsPunctuation = false // Don't add punctuation for line matching
        }

        recognitionRequestLock.lock()
        recognitionRequest = request
        recognitionRequestLock.unlock()
        let generation = sessionGeneration

        // Speech invokes this handler on an internal queue. Marshal every
        // session-state mutation and Flutter event onto the main queue, and
        // ignore callbacks belonging to an already-stopped session.
        recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self] recognitionResult, error in
            let text = recognitionResult?.bestTranscription.formattedString
            let isFinal = recognitionResult?.isFinal ?? false
            let errorDescription = error?.localizedDescription

            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == generation else { return }

                if let text {
                    self.channel.invokeMethod("onResult", arguments: [
                        "text": text,
                        "isFinal": isFinal,
                        "sessionId": sessionId,
                    ])
                }

                if let errorDescription {
                    NSLog("AppleStt: Recognition error: \(errorDescription)")
                    self.stopCurrentSession()
                    self.channel.invokeMethod("onError", arguments: [
                        "error": errorDescription,
                        "sessionId": sessionId,
                    ])
                    self.channel.invokeMethod(
                        "onDone",
                        arguments: ["sessionId": sessionId]
                    )
                } else if isFinal {
                    self.stopCurrentSession()
                    self.channel.invokeMethod(
                        "onDone",
                        arguments: ["sessionId": sessionId]
                    )
                }
            }
        }

        // Install audio tap and start engine
        let inputNode = audioEngine.inputNode

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        tapFormat = recordingFormat // cache for startRecording

        // The mic tap: feed the recognizer, mirror buffers to the recording
        // file, and report mic energy. Defined once so both the iOS
        // (exception-guarded) and macOS install paths share it.
        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            guard let self else { return }
            self.appendToRecognitionRequest(buffer, request: request)
            // Concurrent recording uses a bounded pool allocated by
            // startRecording. The render thread only copies into a free
            // buffer; the file queue owns that buffer until the write ends.
            self.enqueueRecordingBuffer(buffer)
            // Mic energy for Dart-side endpointing and level UI.
            // ~12 events/sec at 4096 frames — cheap enough to send raw.
            let level = AppleSttPlugin.rmsLevel(buffer: buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.channel.invokeMethod("onLevel", arguments: [
                    "level": level,
                    "sessionId": sessionId,
                ])
            }
        }

        var tapInstalled = false
        #if os(iOS)
        // installTap throws an ObjC NSException (not a Swift error) if a tap
        // is already installed. Wrap in the ObjC exception catcher (reachable
        // via the iOS bridging header).
        ObjCExceptionCatcher.try({
            inputNode.installTap(
                onBus: 0,
                bufferSize: Self.tapBufferSize,
                format: recordingFormat,
                block: tapBlock
            )
            tapInstalled = true
        }, catch: { exception in
            NSLog("AppleStt: installTap exception: \(String(describing: exception))")
        })
        #else
        // macOS has no Runner bridging header for ObjCExceptionCatcher. We
        // already stop the engine and removeTap above, so install directly.
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: recordingFormat,
            block: tapBlock
        )
        tapInstalled = true
        #endif

        guard tapInstalled else {
            NSLog("AppleStt: Failed to install tap, aborting listen")
            stopCurrentSession()
            result(FlutterError(code: "TAP_FAILED", message: "Could not install audio tap", details: nil))
            return
        }
        hasInstalledTap = true

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
        // tapFormat is cached from any PREVIOUS session, so it being non-nil
        // doesn't mean audio is flowing — require the engine to actually be
        // running or we'd report success while capturing nothing.
        guard audioEngine.isRunning, let format = tapFormat else {
            NSLog("AppleStt: startRecording FAILED — engine not running or no tap format")
            result(false)
            return
        }
        guard recordingPath == nil else {
            NSLog("AppleStt: startRecording FAILED — a recording is already active")
            result(false)
            return
        }

        // Allocate the bounded pool away from the render callback.
        let buffers = (0..<Self.recordingBufferPoolSize).compactMap { _ in
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: Self.tapBufferSize
            )
        }
        guard buffers.count == Self.recordingBufferPoolSize else {
            result(FlutterError(
                code: "RECORD_ERROR",
                message: "Could not allocate recording buffers",
                details: nil
            ))
            return
        }

        // Each stopped take keeps its own immutable CAF while conversion runs.
        // Re-recording the same destination can therefore start immediately
        // without rewriting an earlier export's input asset.
        let cafPath = path + ".\(UUID().uuidString).caf"
        do {
            let file = try AVAudioFile(
                forWriting: URL(fileURLWithPath: cafPath),
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            audioFileQueue.sync { audioFile = file }

            recordingBufferLock.lock()
            recordingBufferPool = buffers
            recordingActive = true
            recordingBufferLock.unlock()

            recordingPath = path
            recordingCafPath = cafPath
            recordingStartTime = Date()
            NSLog("AppleStt: Recording started → \(cafPath) (PCM \(format.sampleRate)Hz \(format.channelCount)ch)")
            result(true)
        } catch {
            NSLog("AppleStt: Failed to create audio file: \(error)")
            audioFileQueue.sync { audioFile = nil }
            result(FlutterError(
                code: "RECORD_ERROR",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    /// Stop recording, convert CAF→M4A, return {path, durationMs}.
    private func stopRecording(result: @escaping FlutterResult) {
        guard let destPath = recordingPath, let cafPath = recordingCafPath else {
            result(nil)
            return
        }

        let wallDurationMs = Int(
            (Date().timeIntervalSince(recordingStartTime ?? Date())) * 1000
        )

        // Disable capture while holding the ownership lock. A render callback
        // that obtained a pool buffer earlier enqueues its write before
        // releasing this lock, so the following queue sync drains every write.
        recordingBufferLock.lock()
        recordingActive = false
        recordingBufferLock.unlock()
        let hadAudioFile = audioFileQueue.sync {
            let hadAudioFile = audioFile != nil
            audioFile = nil
            return hadAudioFile
        }

        recordingBufferLock.lock()
        recordingBufferPool.removeAll(keepingCapacity: false)
        recordingBufferLock.unlock()
        recordingStartTime = nil
        recordingPath = nil
        recordingCafPath = nil

        guard hadAudioFile else {
            try? FileManager.default.removeItem(atPath: cafPath)
            result(nil)
            return
        }

        let cafSize = (
            try? FileManager.default.attributesOfItem(atPath: cafPath)[.size] as? Int
        ) ?? 0
        NSLog("AppleStt: PCM captured → \(cafPath) (\(wallDurationMs)ms, \(cafSize / 1024)KB)")

        if cafSize < 100 {
            // Return nil, NOT a success-shaped map: destPath may still hold a
            // previous capture, and success would save stale audio as this take.
            NSLog("AppleStt: PCM file too small, discarding")
            try? FileManager.default.removeItem(atPath: cafPath)
            result(nil)
            return
        }

        // Convert PCM CAF → AAC M4A.
        DispatchQueue.global(qos: .userInitiated).async {
            let cafUrl = URL(fileURLWithPath: cafPath)
            let destUrl = URL(fileURLWithPath: destPath)
            let asset = AVAsset(url: cafUrl)
            let sourceDurationMs = Self.milliseconds(
                for: asset.duration,
                fallback: wallDurationMs
            )
            try? FileManager.default.removeItem(at: destUrl)

            guard let exportSession = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                NSLog("AppleStt: No export session available, keeping CAF")
                Self.finishWithCaf(
                    cafUrl: cafUrl,
                    destUrl: destUrl,
                    destPath: destPath,
                    durationMs: sourceDurationMs,
                    result: result
                )
                return
            }

            exportSession.outputURL = destUrl
            exportSession.outputFileType = .m4a

            // Trim leading and trailing silence by analyzing audio amplitude.
            let timeRange = Self.detectSpeechRange(in: asset)
            let outputDurationMs: Int
            if let timeRange {
                exportSession.timeRange = timeRange
                let startMs = Self.milliseconds(for: timeRange.start, fallback: 0)
                let endMs = Self.milliseconds(
                    for: CMTimeAdd(timeRange.start, timeRange.duration),
                    fallback: sourceDurationMs
                )
                outputDurationMs = Self.milliseconds(
                    for: timeRange.duration,
                    fallback: sourceDurationMs
                )
                NSLog("AppleStt: Trimming silence — speech at \(startMs)ms-\(endMs)ms of \(sourceDurationMs)ms")
            } else {
                outputDurationMs = sourceDurationMs
            }

            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    try? FileManager.default.removeItem(at: cafUrl)
                    let m4aSize = (
                        try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int
                    ) ?? 0
                    DispatchQueue.main.async {
                        NSLog("AppleStt: Converted → \(destPath) (\(m4aSize / 1024)KB M4A)")
                        result(["path": destPath, "durationMs": outputDurationMs])
                    }
                } else {
                    // Preserve the untrimmed CAF if conversion fails, and
                    // report its actual source duration rather than a trim.
                    NSLog("AppleStt: Export failed: \(exportSession.error?.localizedDescription ?? "unknown") — keeping raw CAF")
                    try? FileManager.default.removeItem(at: destUrl)
                    Self.finishWithCaf(
                        cafUrl: cafUrl,
                        destUrl: destUrl,
                        destPath: destPath,
                        durationMs: sourceDurationMs,
                        result: result
                    )
                }
            }
        }
    }

    private static func milliseconds(for duration: CMTime, fallback: Int) -> Int {
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds >= 0 else { return fallback }
        return Int((seconds * 1000).rounded())
    }

    private static func finishWithCaf(
        cafUrl: URL,
        destUrl: URL,
        destPath: String,
        durationMs: Int,
        result: @escaping FlutterResult
    ) {
        do {
            try FileManager.default.moveItem(at: cafUrl, to: destUrl)
            DispatchQueue.main.async {
                result(["path": destPath, "durationMs": durationMs])
            }
        } catch {
            NSLog("AppleStt: CAF fallback move failed: \(error)")
            try? FileManager.default.removeItem(at: cafUrl)
            DispatchQueue.main.async { result(nil) }
        }
    }

    /// Analyze audio to find where speech starts and ends.
    /// Returns a time range excluding leading/trailing silence,
    /// with a small padding to avoid cutting off speech edges.
    private static func detectSpeechRange(in asset: AVAsset) -> CMTimeRange? {
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }

        let totalDuration = asset.duration
        let totalSeconds = CMTimeGetSeconds(totalDuration)
        if totalSeconds < 1.0 { return nil } // too short to trim

        // Read audio samples
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        // Analyze in 50ms windows — find RMS amplitude per window.
        // Sample rate from the actual track: mic taps are frequently 48 kHz,
        // and assuming 44.1k drifted every "50ms" window by ~9%, shifting the
        // trim boundaries and clipping the first speech edge after long
        // leading silence.
        let sampleRate: Double = {
            let native = track.naturalTimeScale
            return native > 0 ? Double(native) : 44100.0
        }()
        let windowSamples = Int(sampleRate * 0.05) // 50ms
        var windowRMS: [Float] = []
        // Partial window carried across sample-buffer boundaries.
        var carry: [Float] = []
        carry.reserveCapacity(windowSamples)

        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard let ptr = dataPointer else { continue }

            let count = length / 2
            if count == 0 { continue }

            var floats = [Float](repeating: 0, count: count)
            ptr.withMemoryRebound(to: Int16.self, capacity: count) { int16Ptr in
                vDSP_vflt16(int16Ptr, 1, &floats, 1, vDSP_Length(count))
            }

            var start = 0
            if !carry.isEmpty {
                let need = windowSamples - carry.count
                if count < need {
                    carry.append(contentsOf: floats)
                    continue
                }
                carry.append(contentsOf: floats[0..<need])
                var rms: Float = 0
                vDSP_rmsqv(carry, 1, &rms, vDSP_Length(windowSamples))
                windowRMS.append(rms)
                carry.removeAll(keepingCapacity: true)
                start = need
            }

            floats.withUnsafeBufferPointer { buf in
                var offset = start
                while offset + windowSamples <= count {
                    var rms: Float = 0
                    vDSP_rmsqv(buf.baseAddress! + offset, 1, &rms, vDSP_Length(windowSamples))
                    windowRMS.append(rms)
                    offset += windowSamples
                }
                start = offset
            }
            if start < count {
                carry.append(contentsOf: floats[start...])
            }
        }

        reader.cancelReading()

        if windowRMS.isEmpty { return nil }

        // Find silence threshold: use 5% of peak RMS
        let peakRMS = windowRMS.max() ?? 0
        let threshold = peakRMS * 0.05
        if threshold < 10 { return nil } // entire recording is silent

        // Find first and last windows above threshold
        var firstSpeech = 0
        var lastSpeech = windowRMS.count - 1

        for i in 0..<windowRMS.count {
            if windowRMS[i] > threshold { firstSpeech = i; break }
        }
        for i in stride(from: windowRMS.count - 1, through: 0, by: -1) {
            if windowRMS[i] > threshold { lastSpeech = i; break }
        }

        // Add 150ms padding on each side to avoid cutting off speech edges
        let windowDuration = 0.05 // 50ms per window
        let paddingWindows = 3 // 150ms
        firstSpeech = max(0, firstSpeech - paddingWindows)
        lastSpeech = min(windowRMS.count - 1, lastSpeech + paddingWindows)

        let startTime = CMTime(seconds: Double(firstSpeech) * windowDuration, preferredTimescale: 1000)
        let endTime = CMTime(seconds: Double(lastSpeech + 1) * windowDuration, preferredTimescale: 1000)

        // Only trim if we'd remove at least 300ms total
        let trimmedStart = CMTimeGetSeconds(startTime)
        let trimmedEnd = totalSeconds - CMTimeGetSeconds(endTime)
        if trimmedStart + trimmedEnd < 0.3 { return nil }

        return CMTimeRange(start: startTime, end: endTime)
    }

    /// RMS energy of a PCM buffer (0..1 for float formats).
    private static func rmsLevel(buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        if frames == 0 { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            sum += samples[i] * samples[i]
        }
        return Double(sqrt(sum / Float(frames)))
    }

    private func stopCurrentSession() {
        // Invalidate this session before cancel/endAudio can trigger callbacks.
        // All callers and recognition callback state mutations run on main.
        sessionGeneration &+= 1

        // Stop producing buffers and remove the tap before ending the request.
        // hasInstalledTap also covers engine-start failures, where isRunning is
        // false even though installTap already succeeded.
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        tapFormat = nil

        recognitionRequestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionRequestLock.unlock()

        recognitionTask?.cancel()
        recognitionTask = nil

        // Do NOT deactivate the audio session here. TTS reconfigures it to
        // .playback in KokoroMLXService.synthesize(). Deferred deactivation
        // caused a race condition: it would fire ~2s after STT stopped, killing
        // the audio session right as TTS playback was starting.
    }
}
