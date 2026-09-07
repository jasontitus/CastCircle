#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
import UIKit
#endif
import Speech
import AVFoundation
import Accelerate
import Darwin

/// Serializes append/end without ever waiting in the realtime callback.
/// Teardown may wait for an in-flight append; the render thread only try-locks
/// and drops input if teardown owns the gate.
private final class RecognitionInputGate {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var mutex = pthread_mutex_t()
    private var acceptingInput = true

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
        pthread_mutex_init(&mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(&mutex)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard pthread_mutex_trylock(&mutex) == 0 else { return }
        if acceptingInput {
            request.append(buffer)
        }
        pthread_mutex_unlock(&mutex)
    }

    func endAudio() {
        pthread_mutex_lock(&mutex)
        guard acceptingInput else {
            pthread_mutex_unlock(&mutex)
            return
        }
        acceptingInput = false
        request.endAudio()
        pthread_mutex_unlock(&mutex)
    }
}

private final class AppleSttSession {
    let generation: UInt64
    let input: RecognitionInputGate
    var recognitionTask: SFSpeechRecognitionTask?
    var terminalEventSent = false

    private var levelMutex = pthread_mutex_t()
    private var latestLevel = 0.0
    private var hasLevel = false
    private let levelSource: DispatchSourceUserDataAdd

    init(
        generation: UInt64,
        request: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping (UInt64, Double) -> Void
    ) {
        self.generation = generation
        input = RecognitionInputGate(request: request)
        levelSource = DispatchSource.makeUserDataAddSource(queue: .main)
        pthread_mutex_init(&levelMutex, nil)
        levelSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            pthread_mutex_lock(&self.levelMutex)
            let shouldEmit = self.hasLevel
            let value = self.latestLevel
            self.hasLevel = false
            pthread_mutex_unlock(&self.levelMutex)
            if shouldEmit {
                onLevel(self.generation, value)
            }
        }
        levelSource.resume()
    }

    deinit {
        levelSource.cancel()
        pthread_mutex_destroy(&levelMutex)
    }

    func publishLevel(_ value: Double) {
        guard pthread_mutex_trylock(&levelMutex) == 0 else { return }
        latestLevel = value
        hasLevel = true
        pthread_mutex_unlock(&levelMutex)
        levelSource.add(data: 1)
    }

    func stop() {
        input.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}

final class RecordingBufferSlot {
    let buffer: AVAudioPCMBuffer
    var state = 0 // 0 = free, 1 = ready, 2 = writer owns it
    var enqueueSequence: UInt64 = 0

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

func oldestReadyRecordingSlot(
    in slots: [RecordingBufferSlot]
) -> RecordingBufferSlot? {
    var oldest: RecordingBufferSlot?
    for slot in slots where slot.state == 1 {
        if oldest == nil
            || slot.enqueueSequence < oldest!.enqueueSequence {
            oldest = slot
        }
    }
    return oldest
}

private final class RealtimeRecordingPipeline {
    struct FinishedCapture {
        let cafURL: URL
        let writeError: Error?
    }

    private let writerQueue = DispatchQueue(
        label: "com.lineguide.stt.audiofile",
        qos: .userInitiated
    )
    private var source: DispatchSourceUserDataAdd!
    private var mutex = pthread_mutex_t()
    private var slots: [RecordingBufferSlot] = []
    private var format: AVAudioFormat?
    private var file: AVAudioFile?
    private var cafURL: URL?
    private var acceptingInput = false
    private var writeError: Error?
    private var finishHandler: ((FinishedCapture) -> Void)?
    private var nextEnqueueSequence: UInt64 = 0
    private(set) var droppedBuffers: UInt64 = 0

    init() {
        pthread_mutex_init(&mutex, nil)
        source = DispatchSource.makeUserDataAddSource(queue: writerQueue)
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.resume()
    }

    deinit {
        source.cancel()
        pthread_mutex_destroy(&mutex)
    }

    func prepare(format newFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> Bool {
        pthread_mutex_lock(&mutex)
        defer { pthread_mutex_unlock(&mutex) }

        if let format = format,
           format.isEqual(newFormat),
           slots.first?.buffer.frameCapacity ?? 0 >= frameCapacity {
            return true
        }
        guard file == nil, slots.allSatisfy({ $0.state == 0 }) else {
            return false
        }

        var prepared: [RecordingBufferSlot] = []
        prepared.reserveCapacity(8)
        for _ in 0..<8 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: newFormat,
                frameCapacity: frameCapacity
            ) else {
                return false
            }
            prepared.append(RecordingBufferSlot(buffer: buffer))
        }
        slots = prepared
        format = newFormat
        return true
    }

    func start(file newFile: AVAudioFile, cafURL newURL: URL) -> Bool {
        pthread_mutex_lock(&mutex)
        defer { pthread_mutex_unlock(&mutex) }
        guard file == nil, finishHandler == nil,
              slots.allSatisfy({ $0.state == 0 }) else {
            return false
        }
        file = newFile
        cafURL = newURL
        writeError = nil
        acceptingInput = true
        droppedBuffers = 0
        nextEnqueueSequence = 0
        return true
    }

    func enqueue(_ input: AVAudioPCMBuffer) {
        guard pthread_mutex_trylock(&mutex) == 0 else { return }
        guard acceptingInput, file != nil else {
            pthread_mutex_unlock(&mutex)
            return
        }
        guard let slot = slots.first(where: { $0.state == 0 }),
              Self.copy(input, into: slot.buffer) else {
            droppedBuffers &+= 1
            pthread_mutex_unlock(&mutex)
            return
        }
        slot.enqueueSequence = nextEnqueueSequence
        nextEnqueueSequence &+= 1
        slot.state = 1
        pthread_mutex_unlock(&mutex)
        source.add(data: 1)
    }

    func finish(_ completion: @escaping (FinishedCapture) -> Void) -> Bool {
        pthread_mutex_lock(&mutex)
        guard file != nil, cafURL != nil, finishHandler == nil else {
            pthread_mutex_unlock(&mutex)
            return false
        }
        acceptingInput = false
        finishHandler = completion
        pthread_mutex_unlock(&mutex)
        source.add(data: 1)
        return true
    }

    private func drain() {
        while true {
            pthread_mutex_lock(&mutex)

            if writeError != nil {
                for slot in slots where slot.state == 1 {
                    slot.state = 0
                }
            }

            guard let slot = oldestReadyRecordingSlot(in: slots),
                  let currentFile = file else {
                let hasOwnedSlot = slots.contains(where: { $0.state != 0 })
                if !hasOwnedSlot,
                   let completion = finishHandler,
                   let cafURL = cafURL {
                    let capture = FinishedCapture(
                        cafURL: cafURL,
                        writeError: writeError
                    )
                    file = nil
                    self.cafURL = nil
                    finishHandler = nil
                    pthread_mutex_unlock(&mutex)
                    DispatchQueue.main.async {
                        completion(capture)
                    }
                } else {
                    pthread_mutex_unlock(&mutex)
                }
                return
            }

            slot.state = 2
            pthread_mutex_unlock(&mutex)

            var failure: Error?
            do {
                try currentFile.write(from: slot.buffer)
            } catch {
                failure = error
            }

            pthread_mutex_lock(&mutex)
            slot.state = 0
            if let failure = failure {
                writeError = failure
                acceptingInput = false
            }
            pthread_mutex_unlock(&mutex)
        }
    }

    private static func copy(
        _ input: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        guard input.format.isEqual(destination.format),
              input.frameLength <= destination.frameCapacity else {
            return false
        }

        destination.frameLength = destination.frameCapacity
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            destination.frameLength = 0
            return false
        }

        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let capacity = Int(destinationBuffers[index].mDataByteSize)
            let byteCount = Int(source.mDataByteSize)
            guard byteCount <= capacity,
                  let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData else {
                destination.frameLength = 0
                return false
            }
            memcpy(destinationData, sourceData, byteCount)
        }
        destination.frameLength = input.frameLength
        return true
    }
}

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
    private static let captureFinalizationQueue = DispatchQueue(
        label: "com.lineguide.stt.finalization",
        qos: .userInitiated
    )
    private let audioEngine = AVAudioEngine()
    private let recordingPipeline = RealtimeRecordingPipeline()
    private var activeSession: AppleSttSession?
    private var nextGeneration: UInt64 = 0
    private var authorized = false
    private var recordingStartTime: Date?
    private var recordingPath: String?
    private var tapFormat: AVAudioFormat?

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
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    result(FlutterError(
                        code: "PLUGIN_UNAVAILABLE",
                        message: "Speech plugin was released",
                        details: nil
                    ))
                    return
                }
                self.handle(call, result: result)
            }
            return
        }
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
        result: @escaping FlutterResult
    ) {
        stopCurrentSession()

        if let locale = locale,
           let newRecognizer = SFSpeechRecognizer(
               locale: Locale(identifier: locale)
           ) {
            recognizer = newRecognizer
            NSLog("AppleStt: Switched locale to \(locale)")
        }

        guard authorized, let recognizer = recognizer, recognizer.isAvailable else {
            result(FlutterError(
                code: "NOT_READY",
                message: "Speech recognizer not available",
                details: nil
            ))
            return
        }

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .record,
                mode: .default,
                options: .duckOthers
            )
            try audioSession.setActive(
                true,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            NSLog("AppleStt: Audio session error: \(error)")
            result(FlutterError(
                code: "AUDIO_ERROR",
                message: error.localizedDescription,
                details: nil
            ))
            return
        }
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if onDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
            // Script text is private. Release diagnostics retain only metadata.
            NSLog(
                "AppleStt: Set %d contextual strings for locale %@",
                contextualStrings.count,
                recognizer.locale.identifier
            )
        }
        if #available(iOS 16.0, macOS 13.0, *) {
            request.addsPunctuation = false
        }

        let inputNode = audioEngine.inputNode
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        inputNode.removeTap(onBus: 0)

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingPipeline.prepare(
            format: recordingFormat,
            frameCapacity: 4_096
        ) else {
            result(FlutterError(
                code: "RECORDING_BUSY",
                message: "Active recording format cannot be replaced",
                details: nil
            ))
            return
        }
        tapFormat = recordingFormat

        nextGeneration &+= 1
        let generation = nextGeneration
        let session = AppleSttSession(
            generation: generation,
            request: request
        ) { [weak self] callbackGeneration, level in
            guard let self = self,
                  self.activeSession?.generation == callbackGeneration else {
                return
            }
            self.channel.invokeMethod("onLevel", arguments: level)
        }
        activeSession = session

        session.recognitionTask = recognizer.recognitionTask(
            with: request
        ) { [weak self, weak session] recognitionResult, error in
            DispatchQueue.main.async {
                guard let self = self, let session = session else { return }
                self.handleRecognitionCallback(
                    recognitionResult,
                    error: error,
                    session: session
                )
            }
        }

        let recordingPipeline = self.recordingPipeline
        let tapBlock: AVAudioNodeTapBlock = { [weak session] buffer, _ in
            guard let session = session else { return }
            session.input.append(buffer)
            recordingPipeline.enqueue(buffer)
            session.publishLevel(Self.rmsLevel(buffer: buffer))
        }

        var tapInstalled = false
        #if os(iOS)
        ObjCExceptionCatcher.try({
            inputNode.installTap(
                onBus: 0,
                bufferSize: 4_096,
                format: recordingFormat,
                block: tapBlock
            )
            tapInstalled = true
        }, catch: { exception in
            NSLog(
                "AppleStt: installTap exception: \(String(describing: exception))"
            )
        })
        #else
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: recordingFormat,
            block: tapBlock
        )
        tapInstalled = true
        #endif

        guard tapInstalled else {
            stopCurrentSession(ifActive: session)
            result(FlutterError(
                code: "TAP_FAILED",
                message: "Could not install audio tap",
                details: nil
            ))
            return
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            NSLog("AppleStt: Listening started (generation \(generation))")
            result(true)
        } catch {
            NSLog("AppleStt: Engine start error: \(error)")
            stopCurrentSession(ifActive: session)
            result(FlutterError(
                code: "ENGINE_ERROR",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleRecognitionCallback(
        _ recognitionResult: SFSpeechRecognitionResult?,
        error: Error?,
        session: AppleSttSession
    ) {
        guard activeSession === session,
              !session.terminalEventSent else {
            return
        }

        if let recognitionResult = recognitionResult {
            channel.invokeMethod("onResult", arguments: [
                "text": recognitionResult.bestTranscription.formattedString,
                "isFinal": recognitionResult.isFinal,
            ])
            if recognitionResult.isFinal {
                finish(session: session, error: nil)
                return
            }
        }

        if let error = error {
            finish(session: session, error: error)
        }
    }

    private func finish(session: AppleSttSession, error: Error?) {
        guard activeSession === session,
              !session.terminalEventSent else {
            return
        }
        session.terminalEventSent = true
        stopCurrentSession(ifActive: session)
        if let error = error {
            NSLog(
                "AppleStt: Recognition error in generation %llu: %@",
                session.generation,
                error.localizedDescription
            )
            channel.invokeMethod(
                "onError",
                arguments: error.localizedDescription
            )
        }
        channel.invokeMethod("onDone", arguments: nil)
    }

    private func stopListening(result: @escaping FlutterResult) {
        stopCurrentSession()
        result(nil)
    }

    // MARK: - Concurrent Recording

    /// Start recording audio to a file alongside STT.
    /// The audio is captured from the same AVAudioEngine tap.
    private func startRecording(path: String, result: @escaping FlutterResult) {
        guard audioEngine.isRunning, activeSession != nil,
              let format = tapFormat else {
            NSLog(
                "AppleStt: startRecording FAILED — engine not running or no tap format"
            )
            result(false)
            return
        }
        guard !path.isEmpty,
              URL(fileURLWithPath: path).pathExtension.lowercased() == "m4a"
        else {
            result(FlutterError(
                code: "INVALID_RECORDING_PATH",
                message: "Recording destination must use an .m4a extension",
                details: nil
            ))
            return
        }


        let destinationURL = URL(fileURLWithPath: path)
        let cafURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).\(UUID().uuidString).recovery.caf"
            )

        do {
            let file = try AVAudioFile(
                forWriting: cafURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            guard recordingPipeline.start(file: file, cafURL: cafURL) else {
                try? FileManager.default.removeItem(at: cafURL)
                result(FlutterError(
                    code: "ALREADY_RECORDING",
                    message: "A recording is already active",
                    details: nil
                ))
                return
            }
            recordingPath = path
            recordingStartTime = Date()
            NSLog(
                "AppleStt: Recording started (PCM %.0fHz %uch)",
                format.sampleRate,
                format.channelCount
            )
            result(true)
        } catch {
            NSLog("AppleStt: Failed to create audio file: \(error)")
            result(FlutterError(
                code: "RECORD_ERROR",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    /// Drains the bounded writer and converts its recovery CAF to a validated
    /// temporary M4A. Only an atomic rename may replace the prior take.
    private func stopRecording(result: @escaping FlutterResult) {
        guard let destinationPath = recordingPath else {
            result(nil)
            return
        }
        let durationMs = Int(
            Date().timeIntervalSince(recordingStartTime ?? Date()) * 1_000
        )

        guard recordingPipeline.finish({ capture in
            if let writeError = capture.writeError {
                NSLog(
                    "AppleStt: Recording writer stopped after error: \(writeError)"
                )
                Self.completeCaptureFailure(
                    code: "RECORD_WRITE_FAILED",
                    message: "Audio capture could not be completed",
                    cafURL: capture.cafURL,
                    destinationURL: URL(fileURLWithPath: destinationPath),
                    result: result
                )
                return
            }
            Self.finalizeCapture(
                cafURL: capture.cafURL,
                destinationURL: URL(fileURLWithPath: destinationPath),
                durationMs: durationMs,
                result: result
            )
        }) else {
            result(nil)
            return
        }

        recordingPath = nil
        recordingStartTime = nil
    }

    private static func finalizeCapture(
        cafURL: URL,
        destinationURL: URL,
        durationMs: Int,
        result: @escaping FlutterResult
    ) {
        captureFinalizationQueue.async {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: cafURL.path
            )
            let cafSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard cafSize >= 100 else {
                completeCaptureFailure(
                    code: "CAPTURE_INVALID",
                    message: "Captured audio is empty or invalid",
                    cafURL: cafURL,
                    destinationURL: destinationURL,
                    result: result
                )
                return
            }

            let temporaryURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp.m4a"
                )
            let sourceAsset = AVAsset(url: cafURL)
            guard let exportSession = AVAssetExportSession(
                asset: sourceAsset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                completeCaptureFailure(
                    code: "EXPORT_UNAVAILABLE",
                    message: "M4A conversion is unavailable",
                    cafURL: cafURL,
                    destinationURL: destinationURL,
                    result: result
                )
                return
            }

            exportSession.outputURL = temporaryURL
            exportSession.outputFileType = .m4a
            if let timeRange = detectSpeechRange(in: sourceAsset) {
                exportSession.timeRange = timeRange
            }

            let exportFinished = DispatchSemaphore(value: 0)
            exportSession.exportAsynchronously {
                defer { exportFinished.signal() }
                guard exportSession.status == .completed else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    completeCaptureFailure(
                        code: "EXPORT_FAILED",
                        message: exportSession.error?.localizedDescription
                            ?? "M4A conversion failed",
                        cafURL: cafURL,
                        destinationURL: destinationURL,
                        result: result
                    )
                    return
                }

                guard validateM4A(at: temporaryURL) else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    completeCaptureFailure(
                        code: "EXPORT_INVALID",
                        message: "Converted M4A failed validation",
                        cafURL: cafURL,
                        destinationURL: destinationURL,
                        result: result
                    )
                    return
                }

                guard let replacementError = atomicallyReplace(
                    temporaryURL: temporaryURL,
                    destinationURL: destinationURL
                ) else {
                    try? FileManager.default.removeItem(at: cafURL)
                    DispatchQueue.main.async {
                        result([
                            "path": destinationURL.path,
                            "durationMs": durationMs,
                            "format": "m4a",
                        ])
                    }
                    return
                }
                let failure = String(
                    cString: strerror(replacementError)
                )
                try? FileManager.default.removeItem(at: temporaryURL)
                completeCaptureFailure(
                    code: "REPLACE_FAILED",
                    message: "Could not adopt converted M4A: \(failure)",
                    cafURL: cafURL,
                    destinationURL: destinationURL,
                    result: result
                )
            }
            exportFinished.wait()
        }
    }

    /// POSIX rename replaces a same-volume destination atomically: a failure
    /// leaves the existing destination untouched.
    static func atomicallyReplace(
        temporaryURL: URL,
        destinationURL: URL
    ) -> Int32? {
        temporaryURL.path.withCString { source in
            destinationURL.path.withCString { destination in
                guard Darwin.rename(source, destination) != 0 else {
                    return nil
                }
                return errno
            }
        }
    }

    private static func validateM4A(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        let header = handle.readData(ofLength: 12)
        try? handle.close()
        guard header.count >= 12,
              String(
                  data: header.subdata(in: 4..<8),
                  encoding: .ascii
              ) == "ftyp",
              let file = try? AVAudioFile(forReading: url) else {
            return false
        }
        return file.length > 0 && file.processingFormat.channelCount > 0
    }

    private static func completeCaptureFailure(
        code: String,
        message: String,
        cafURL: URL,
        destinationURL: URL,
        result: @escaping FlutterResult
    ) {
        NSLog(
            "AppleStt: %@; recovery CAF retained at %@",
            message,
            cafURL.lastPathComponent
        )
        DispatchQueue.main.async {
            result(FlutterError(
                code: code,
                message: message,
                details: [
                    "destinationPath": destinationURL.path,
                    "recovery": [
                        "path": cafURL.path,
                        "format": "caf",
                    ],
                ]
            ))
        }
    }

    /// Analyze audio to find where speech starts and ends.
    /// Returns a time range excluding leading/trailing silence,
    /// with a small padding to avoid cutting off speech edges.
    static func detectSpeechRange(in asset: AVAsset) -> CMTimeRange? {
        guard let track = asset.tracks(withMediaType: .audio).first else {
            return nil
        }

        let totalDuration = asset.duration
        let totalSeconds = CMTimeGetSeconds(totalDuration)
        guard totalSeconds.isFinite, totalSeconds >= 1.0,
              let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var sampleRate = 0.0
        var channelCount = 0
        var windowFrames = 0
        var framesInWindow = 0
        var squareSum = 0.0
        var windowRMS: [Float] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if windowFrames == 0,
               let description = CMSampleBufferGetFormatDescription(
                   sampleBuffer
               ),
               let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
                   description
               )?.pointee {
                sampleRate = stream.mSampleRate
                channelCount = Int(stream.mChannelsPerFrame)
                windowFrames = max(1, Int(sampleRate * 0.05))
            }
            guard sampleRate > 0, channelCount > 0, windowFrames > 0,
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            else {
                continue
            }

            var byteLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let pointerStatus = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &byteLength,
                dataPointerOut: &dataPointer
            )
            guard pointerStatus == kCMBlockBufferNoErr,
                  let dataPointer = dataPointer else {
                continue
            }

            let availableSamples = byteLength / MemoryLayout<Int16>.size
            let declaredFrames = CMSampleBufferGetNumSamples(sampleBuffer)
            let frameCount = min(
                declaredFrames,
                availableSamples / channelCount
            )
            let samples = dataPointer.withMemoryRebound(
                to: Int16.self,
                capacity: availableSamples
            ) { $0 }

            for frame in 0..<frameCount {
                let frameOffset = frame * channelCount
                for channel in 0..<channelCount {
                    let value = Double(samples[frameOffset + channel])
                    squareSum += value * value
                }
                framesInWindow += 1

                if framesInWindow == windowFrames {
                    let divisor = Double(windowFrames * channelCount)
                    windowRMS.append(Float((squareSum / divisor).squareRoot()))
                    framesInWindow = 0
                    squareSum = 0
                }
            }
        }
        reader.cancelReading()

        guard !windowRMS.isEmpty else { return nil }
        let peakRMS = windowRMS.max() ?? 0
        let threshold = peakRMS * 0.05
        guard threshold >= 10 else { return nil }

        guard let firstDetected = windowRMS.firstIndex(
            where: { $0 > threshold }
        ), let lastDetected = windowRMS.lastIndex(
            where: { $0 > threshold }
        ) else {
            return nil
        }

        let paddingWindows = 3
        let firstSpeech = max(0, firstDetected - paddingWindows)
        let lastSpeech = min(
            windowRMS.count - 1,
            lastDetected + paddingWindows
        )
        let windowDuration = Double(windowFrames) / sampleRate
        let startTime = CMTime(
            seconds: Double(firstSpeech) * windowDuration,
            preferredTimescale: 1_000
        )
        let rawEnd = CMTime(
            seconds: Double(lastSpeech + 1) * windowDuration,
            preferredTimescale: 1_000
        )
        let endTime = CMTimeCompare(rawEnd, totalDuration) > 0
            ? totalDuration
            : rawEnd

        let trimmedStart = CMTimeGetSeconds(startTime)
        let trimmedEnd = max(0, totalSeconds - CMTimeGetSeconds(endTime))
        guard trimmedStart + trimmedEnd >= 0.3,
              CMTimeCompare(endTime, startTime) > 0 else {
            return nil
        }
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

    private func stopCurrentSession(
        ifActive expectedSession: AppleSttSession? = nil
    ) {
        if let expectedSession = expectedSession,
           activeSession !== expectedSession {
            return
        }
        guard let session = activeSession else { return }

        // Invalidate ownership first so already-queued recognition/level
        // callbacks become stale before cancellation can trigger them.
        activeSession = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        session.stop()
        tapFormat = nil

        // Do NOT deactivate the audio session here. TTS reconfigures it to
        // playback, and deferred deactivation can kill a new playback session.
    }
}
