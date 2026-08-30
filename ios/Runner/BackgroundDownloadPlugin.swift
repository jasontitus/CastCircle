import Flutter
import UIKit

/// Native iOS plugin for resumable background model downloads.
class BackgroundDownloadPlugin: NSObject, URLSessionDownloadDelegate {
    static let channelName = "com.lineguide/background_download"

    private let channel: FlutterMethodChannel
    private var session: URLSession!
    private var activeDownloads: [String: DownloadInfo] = [:]
    private var lastProgressEmit: [String: (fraction: Double, at: Date)] = [:]
    private let maxAutoRetries = 6

    private final class DownloadInfo {
        let modelId: String
        let url: URL
        let destinationPath: String
        let generation: String
        var task: URLSessionDownloadTask?
        var taskIdentifier: Int?
        var retryCount = 0
        var retryWorkItem: DispatchWorkItem?

        init(modelId: String, url: URL, destinationPath: String, generation: String = UUID().uuidString) {
            self.modelId = modelId
            self.url = url
            self.destinationPath = destinationPath
            self.generation = generation
        }
    }

    /// The resume data and the immutable request identity it belongs to. Raw
    /// URLSession resume blobs from older builds deliberately fail decoding and
    /// are discarded rather than being applied to a different release URL.
    private struct ResumeEnvelope: Codable {
        let version: Int
        let modelId: String
        let url: String
        let resumeData: Data
    }

    private enum ResumeFileError: LocalizedError {
        case read(Error)
        case remove(Error)
        case write(Error)

        var errorDescription: String? {
            switch self {
            case .read(let error):
                return "Could not read saved download progress: \(error.localizedDescription)"
            case .remove(let error):
                return "Could not discard incompatible download progress: \(error.localizedDescription)"
            case .write(let error):
                return "Could not save download progress: \(error.localizedDescription)"
            }
        }
    }

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()

        let config = URLSessionConfiguration.background(
            withIdentifier: "com.lineguide.modeldownload"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        channel.setMethodCallHandler(handle)
    }

    private func resumePath(_ destinationPath: String) -> String {
        destinationPath + ".resume"
    }

    // MARK: - Download-state persistence

    private static let persistKey = "BackgroundDownloadPlugin.active"

    private func persistDownloadRecord(_ info: DownloadInfo) {
        var records = UserDefaults.standard.dictionary(forKey: Self.persistKey)
            as? [String: [String: String]] ?? [:]
        var record = [
            "url": info.url.absoluteString,
            "destinationPath": info.destinationPath,
            "generation": info.generation,
        ]
        if let taskIdentifier = info.taskIdentifier {
            record["taskIdentifier"] = String(taskIdentifier)
        }
        records[info.modelId] = record
        UserDefaults.standard.set(records, forKey: Self.persistKey)
    }

    private func removeDownloadRecord(_ info: DownloadInfo) {
        var records = UserDefaults.standard.dictionary(forKey: Self.persistKey)
            as? [String: [String: String]] ?? [:]
        guard records[info.modelId]?["generation"] == info.generation else { return }
        records.removeValue(forKey: info.modelId)
        UserDefaults.standard.set(records, forKey: Self.persistKey)
    }

    private func restoredDownloadInfo(generation: String, taskIdentifier: Int) -> DownloadInfo? {
        guard let records = UserDefaults.standard.dictionary(forKey: Self.persistKey)
                as? [String: [String: String]] else { return nil }
        for (modelId, record) in records where record["generation"] == generation {
            guard let urlString = record["url"],
                  let url = URL(string: urlString),
                  let destinationPath = record["destinationPath"],
                  record["taskIdentifier"].flatMap({ Int($0) }) == taskIdentifier else { continue }
            let info = DownloadInfo(
                modelId: modelId,
                url: url,
                destinationPath: destinationPath,
                generation: generation
            )
            info.taskIdentifier = taskIdentifier
            NSLog("BackgroundDownload: \(modelId) restored generation \(generation) after relaunch")
            return info
        }
        return nil
    }

    private func persistedDownloadInfo(modelId: String) -> DownloadInfo? {
        guard let records = UserDefaults.standard.dictionary(forKey: Self.persistKey)
                as? [String: [String: String]],
              let record = records[modelId],
              let generation = record["generation"],
              let urlString = record["url"],
              let url = URL(string: urlString),
              let destinationPath = record["destinationPath"] else {
            return nil
        }
        let info = DownloadInfo(
            modelId: modelId,
            url: url,
            destinationPath: destinationPath,
            generation: generation
        )
        if let taskIdentifierString = record["taskIdentifier"] {
            info.taskIdentifier = Int(taskIdentifierString)
        }
        return info
    }

    private func persistedGeneration(modelId: String) -> String? {
        let records = UserDefaults.standard.dictionary(forKey: Self.persistKey)
            as? [String: [String: String]]
        return records?[modelId]?["generation"]
    }

    private func finishCancellation(_ info: DownloadInfo, result: @escaping FlutterResult) {
        do {
            try removeResumeFileIfPresent(for: info)
        } catch {
            NSLog("BackgroundDownload: \(info.modelId) cancel could not clear resume state: \(error)")
            removeDownloadRecord(info)
            result(FlutterError(
                code: "RESUME_CLEANUP_FAILED",
                message: error.localizedDescription,
                details: ["modelId": info.modelId]
            ))
            return
        }
        removeDownloadRecord(info)
        result(true)
    }

    /// Resolve a callback only when both its generation and URLSession task ID
    /// still identify the active transfer. A late callback from a replaced task
    /// must never read, mutate, or remove its replacement's state.
    private func info(for task: URLSessionTask, allowRestore: Bool = true) -> DownloadInfo? {
        guard let generation = task.taskDescription else { return nil }
        if let info = activeDownloads.values.first(where: {
            $0.generation == generation && $0.taskIdentifier == task.taskIdentifier
        }) {
            return info
        }
        guard allowRestore else { return nil }
        return restoredDownloadInfo(generation: generation, taskIdentifier: task.taskIdentifier)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startDownload":
            guard let args = call.arguments as? [String: Any],
                  let modelId = args["modelId"] as? String,
                  let urlString = args["url"] as? String,
                  let destinationPath = args["destinationPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
                return
            }
            guard let downloadURL = URL(string: urlString) else {
                result(FlutterError(code: "INVALID_URL", message: "Invalid URL", details: nil))
                return
            }

            do {
                let destinationDirectory = (destinationPath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(
                    atPath: destinationDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                if let existing = activeDownloads.removeValue(forKey: modelId) {
                    existing.retryWorkItem?.cancel()
                    existing.task?.cancel()
                    removeDownloadRecord(existing)
                }

                let info = DownloadInfo(
                    modelId: modelId,
                    url: downloadURL,
                    destinationPath: destinationPath
                )
                activeDownloads[modelId] = info
                do {
                    try startTask(info)
                    persistDownloadRecord(info)
                    result(true)
                } catch {
                    activeDownloads.removeValue(forKey: modelId)
                    removeDownloadRecord(info)
                    throw error
                }
            } catch {
                NSLog("BackgroundDownload: \(modelId) could not start: \(error)")
                result(FlutterError(
                    code: "DOWNLOAD_START_FAILED",
                    message: error.localizedDescription,
                    details: ["modelId": modelId, "resuming": false]
                ))
            }

        case "cancelDownload":
            guard let args = call.arguments as? [String: Any],
                  let modelId = args["modelId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing modelId", details: nil))
                return
            }
            if let info = activeDownloads.removeValue(forKey: modelId) {
                info.retryWorkItem?.cancel()
                info.task?.cancel()
                finishCancellation(info, result: result)
                return
            }

            guard let restored = persistedDownloadInfo(modelId: modelId) else {
                result(true)
                return
            }
            let restoredGeneration = restored.generation
            // A background URLSession outlives this plugin instance. Resolve
            // cancellation only after locating and cancelling the exact
            // persisted generation/task pair.
            session.getAllTasks { tasks in
                DispatchQueue.main.async {
                    let matchingTask = tasks.first {
                        guard $0.taskDescription == restoredGeneration else { return false }
                        guard let persistedTaskIdentifier = restored.taskIdentifier else { return true }
                        return $0.taskIdentifier == persistedTaskIdentifier
                    }
                    matchingTask?.cancel()

                    // A newer start may have replaced the record while the
                    // asynchronous task lookup was in flight. Never clear its
                    // resume file or persisted state.
                    guard self.persistedGeneration(modelId: modelId) == restoredGeneration else {
                        result(true)
                        return
                    }
                    if let current = self.activeDownloads[modelId],
                       current.generation == restoredGeneration {
                        self.activeDownloads.removeValue(forKey: modelId)
                        current.retryWorkItem?.cancel()
                        current.task?.cancel()
                    }
                    self.finishCancellation(restored, result: result)
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Build and resume the task. Resume data is usable only for the exact
    /// model ID and immutable source URL that produced it.
    private func startTask(_ info: DownloadInfo) throws {
        let task: URLSessionDownloadTask
        if let resumeData = try matchingResumeData(for: info) {
            NSLog("BackgroundDownload: \(info.modelId) resuming with \(resumeData.count) bytes of resume data")
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: info.url)
        }
        task.taskDescription = info.generation
        info.task = task
        info.taskIdentifier = task.taskIdentifier
        task.resume()
    }

    private func matchingResumeData(for info: DownloadInfo) throws -> Data? {
        let fileURL = URL(fileURLWithPath: resumePath(info.destinationPath))
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let encoded: Data
        do {
            encoded = try Data(contentsOf: fileURL)
        } catch {
            throw ResumeFileError.read(error)
        }

        let envelope: ResumeEnvelope?
        do {
            envelope = try PropertyListDecoder().decode(ResumeEnvelope.self, from: encoded)
        } catch {
            NSLog("BackgroundDownload: \(info.modelId) resume envelope is unreadable: \(error)")
            envelope = nil
        }
        guard let envelope = envelope,
              envelope.version == 1,
              envelope.modelId == info.modelId,
              envelope.url == info.url.absoluteString,
              !envelope.resumeData.isEmpty else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw ResumeFileError.remove(error)
            }
            NSLog("BackgroundDownload: \(info.modelId) discarded resume data for a different model URL")
            return nil
        }
        return envelope.resumeData
    }

    private func saveResumeData(_ data: Data, for info: DownloadInfo) throws {
        let envelope = ResumeEnvelope(
            version: 1,
            modelId: info.modelId,
            url: info.url.absoluteString,
            resumeData: data
        )
        do {
            let encoded = try PropertyListEncoder().encode(envelope)
            try encoded.write(
                to: URL(fileURLWithPath: resumePath(info.destinationPath)),
                options: .atomic
            )
        } catch {
            throw ResumeFileError.write(error)
        }
    }

    private func removeResumeFileIfPresent(for info: DownloadInfo) throws {
        let path = resumePath(info.destinationPath)
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw ResumeFileError.remove(error)
        }
    }

    private func finishWithResumePersistenceError(_ error: Error, info: DownloadInfo) {
        NSLog("BackgroundDownload: \(info.modelId) resume persistence failed: \(error)")
        channel.invokeMethod("onDownloadError", arguments: [
            "modelId": info.modelId,
            "error": error.localizedDescription,
            "resuming": false,
            "errorCode": "RESUME_PERSISTENCE_FAILED",
        ])
        if activeDownloads[info.modelId]?.generation == info.generation {
            activeDownloads.removeValue(forKey: info.modelId)
        }
        removeDownloadRecord(info)
    }

    private func scheduleRetry(_ info: DownloadInfo, resuming: Bool) {
        guard activeDownloads[info.modelId]?.generation == info.generation else { return }
        info.retryCount += 1
        info.task = nil
        info.taskIdentifier = nil

        if info.retryCount > maxAutoRetries {
            NSLog("BackgroundDownload: \(info.modelId) exhausted \(maxAutoRetries) retries")
            channel.invokeMethod("onDownloadError", arguments: [
                "modelId": info.modelId,
                "error": "Network interrupted. Tap Download to resume.",
                "resuming": resuming,
            ])
            activeDownloads.removeValue(forKey: info.modelId)
            removeDownloadRecord(info)
            return
        }

        let generation = info.generation
        let delay = min(pow(2.0, Double(info.retryCount)), 30.0)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self,
                  let current = self.activeDownloads[info.modelId],
                  current.generation == generation,
                  current.task == nil else { return }
            current.retryWorkItem = nil
            do {
                try self.startTask(current)
                self.persistDownloadRecord(current)
            } catch {
                self.finishWithResumePersistenceError(error, info: current)
            }
        }
        info.retryWorkItem?.cancel()
        info.retryWorkItem = workItem
        activeDownloads[info.modelId] = info
        persistDownloadRecord(info)
        NSLog("BackgroundDownload: \(info.modelId) retry \(info.retryCount) in \(Int(delay))s (resuming: \(resuming))")
        channel.invokeMethod("onDownloadRetry", arguments: [
            "modelId": info.modelId,
            "retry": info.retryCount,
            "resuming": resuming,
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let info = info(for: downloadTask) else {
            NSLog("BackgroundDownload: ignored completion from stale task \(downloadTask.taskIdentifier)")
            return
        }

        let destinationURL = URL(fileURLWithPath: info.destinationPath)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: location,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: location, to: destinationURL)
            }
            do {
                try removeResumeFileIfPresent(for: info)
            } catch {
                NSLog("BackgroundDownload: \(info.modelId) completed but resume cleanup failed: \(error)")
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: info.destinationPath)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            NSLog("BackgroundDownload: \(info.modelId) complete (\(size / 1024 / 1024) MB)")
            channel.invokeMethod("onDownloadComplete", arguments: [
                "modelId": info.modelId,
                "path": info.destinationPath,
                "size": size,
            ])
        } catch {
            NSLog("BackgroundDownload: \(info.modelId) move failed: \(error)")
            channel.invokeMethod("onDownloadError", arguments: [
                "modelId": info.modelId,
                "error": "Failed to save file: \(error.localizedDescription)",
            ])
        }

        if activeDownloads[info.modelId]?.generation == info.generation {
            info.retryWorkItem?.cancel()
            activeDownloads.removeValue(forKey: info.modelId)
            lastProgressEmit.removeValue(forKey: info.modelId)
        }
        removeDownloadRecord(info)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let info = info(for: downloadTask) else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0
        let now = Date()
        if let last = lastProgressEmit[info.modelId],
           progress < 1.0,
           progress - last.fraction < 0.01,
           now.timeIntervalSince(last.at) < 0.3 {
            return
        }
        lastProgressEmit[info.modelId] = (progress, now)
        channel.invokeMethod("onDownloadProgress", arguments: [
            "modelId": info.modelId,
            "progress": progress,
            "bytesWritten": totalBytesWritten,
            "totalBytes": totalBytesExpectedToWrite,
        ])
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        guard let info = info(for: task) else {
            NSLog("BackgroundDownload: ignored error from stale task \(task.taskIdentifier)")
            return
        }

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }

        if activeDownloads[info.modelId] == nil {
            activeDownloads[info.modelId] = info
        }
        guard activeDownloads[info.modelId]?.generation == info.generation else { return }

        let resuming: Bool
        do {
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !resumeData.isEmpty {
                try saveResumeData(resumeData, for: info)
                resuming = true
                NSLog("BackgroundDownload: \(info.modelId) saved \(resumeData.count) bytes of resume data")
            } else {
                try removeResumeFileIfPresent(for: info)
                resuming = false
                NSLog("BackgroundDownload: \(info.modelId) retry will restart because the server supplied no resume data")
            }
        } catch {
            finishWithResumePersistenceError(error, info: info)
            return
        }
        scheduleRetry(info, resuming: resuming)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            (UIApplication.shared.delegate as? AppDelegate)?.backgroundSessionCompletionHandler?()
            (UIApplication.shared.delegate as? AppDelegate)?.backgroundSessionCompletionHandler = nil
        }
    }
}
