import Flutter
import UIKit

/// Native iOS plugin for background file downloads using URLSession.
///
/// Uses a background URLSession configuration so downloads survive screen
/// sleep, app suspension, and even app termination. Large downloads (multi-GB
/// models on flaky networks) are **resumable**: on a network error the
/// partial-transfer resume data is persisted to disk, the download auto-retries
/// with backoff, and a later manual retry (or app relaunch) continues from where
/// it left off instead of restarting from zero.
class BackgroundDownloadPlugin: NSObject, URLSessionDownloadDelegate {
    static let channelName = "com.lineguide/background_download"

    private let channel: FlutterMethodChannel
    private var session: URLSession!
    private var activeDownloads: [String: DownloadInfo] = [:]
    private var retryWorkItems: [String: DispatchWorkItem] = [:]
    private var retryGenerations: [String: UUID] = [:]

    /// How many times to auto-retry a failed transfer before surfacing the
    /// error to the UI (which can still resume later via a manual re-tap).
    private let maxAutoRetries = 6

    struct DownloadInfo {
        let modelId: String
        let url: URL
        let destinationPath: String
        var task: URLSessionDownloadTask?
        var retryCount: Int = 0
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
        // Wait for connectivity rather than failing instantly when the network
        // drops — the system holds the task and resumes when a path returns.
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        channel.setMethodCallHandler(handle)
        restoreBackgroundTasks()
    }

    /// Resume data and its source URL are stored together by destination.
    /// Missing or mismatched metadata fails closed to a fresh request.
    private func resumePath(_ destinationPath: String) -> String {
        destinationPath + ".resume"
    }

    private func resumeURLPath(_ destinationPath: String) -> String {
        destinationPath + ".resume.url"
    }

    private func clearResumeData(_ destinationPath: String) {
        try? FileManager.default.removeItem(atPath: resumePath(destinationPath))
        try? FileManager.default.removeItem(atPath: resumeURLPath(destinationPath))
    }

    private func resumeData(for info: DownloadInfo) -> Data? {
        guard let storedURL = try? String(
                contentsOfFile: resumeURLPath(info.destinationPath),
                encoding: .utf8
              ),
              storedURL == info.url.absoluteString,
              let data = try? Data(contentsOf: URL(fileURLWithPath: resumePath(info.destinationPath))),
              !data.isEmpty else {
            clearResumeData(info.destinationPath)
            return nil
        }
        return data
    }

    private func persistResumeData(_ data: Data, for info: DownloadInfo) {
        do {
            try data.write(
                to: URL(fileURLWithPath: resumePath(info.destinationPath)),
                options: .atomic
            )
            try Data(info.url.absoluteString.utf8).write(
                to: URL(fileURLWithPath: resumeURLPath(info.destinationPath)),
                options: .atomic
            )
        } catch {
            clearResumeData(info.destinationPath)
            NSLog("BackgroundDownload: \(info.modelId) could not persist resume data: \(error)")
        }
    }

    // MARK: - Download-state persistence
    //
    // activeDownloads is memory-only, but a BACKGROUND URLSession outlives
    // the process: iOS relaunches the app and replays didFinishDownloadingTo
    // with taskDescription intact. The fresh plugin instance used to have an
    // empty dict, so the guard dropped the callback, the temp file was
    // deleted by the system, and a multi-GB download that completed while
    // terminated was silently discarded. Persist modelId → (url, dest) and
    // reconstruct on replay.

    private static let persistKey = "BackgroundDownloadPlugin.active"

    private func persistDownloadRecord(_ info: DownloadInfo) {
        var records = UserDefaults.standard.dictionary(forKey: Self.persistKey)
            as? [String: [String: String]] ?? [:]
        records[info.modelId] = [
            "url": info.url.absoluteString,
            "destinationPath": info.destinationPath,
            "retryCount": String(info.retryCount),
        ]
        UserDefaults.standard.set(records, forKey: Self.persistKey)
    }

    private func removeDownloadRecord(_ modelId: String) {
        var records = UserDefaults.standard.dictionary(forKey: Self.persistKey)
            as? [String: [String: String]] ?? [:]
        records.removeValue(forKey: modelId)
        UserDefaults.standard.set(records, forKey: Self.persistKey)
    }

    /// Rebuild a DownloadInfo for a delegate callback that arrived after the
    /// process (and activeDownloads) was recreated.
    private func restoredDownloadInfo(_ modelId: String) -> DownloadInfo? {
        guard let records = UserDefaults.standard.dictionary(forKey: Self.persistKey)
                as? [String: [String: String]],
              let record = records[modelId],
              let urlString = record["url"],
              let url = URL(string: urlString),
              let dest = record["destinationPath"] else { return nil }
        let retryCount = record["retryCount"].flatMap(Int.init) ?? 0
        NSLog("BackgroundDownload: \(modelId) restored from persisted state (post-relaunch delivery)")
        return DownloadInfo(
            modelId: modelId,
            url: url,
            destinationPath: dest,
            retryCount: max(0, retryCount)
        )
    }

    private func requestMatches(_ task: URLSessionTask, info: DownloadInfo) -> Bool {
        let requestURL = task.originalRequest?.url ?? task.currentRequest?.url
        return requestURL == info.url
    }

    /// Reattach the live tasks owned by the background session after relaunch.
    /// Persisted URL metadata is authoritative: mismatched or duplicate tasks
    /// are cancelled before they can consume more network or overwrite a file.
    private func restoreBackgroundTasks() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var infos: [String: DownloadInfo] = [:]
                var matchingTasks: [String: [URLSessionDownloadTask]] = [:]

                for task in tasks {
                    guard let modelId = task.taskDescription,
                          let info = infos[modelId] ?? self.restoredDownloadInfo(modelId),
                          let downloadTask = task as? URLSessionDownloadTask,
                          self.requestMatches(downloadTask, info: info) else {
                        task.cancel()
                        continue
                    }
                    infos[modelId] = info
                    matchingTasks[modelId, default: []].append(downloadTask)
                }

                for (modelId, var candidates) in matchingTasks {
                    guard var info = infos[modelId] else { continue }

                    // A task created after getAllTasks took its snapshot may
                    // already be in memory. Include it in the same selection.
                    if let currentTask = self.activeDownloads[modelId]?.task,
                       !candidates.contains(where: {
                           $0.taskIdentifier == currentTask.taskIdentifier
                       }) {
                        if self.requestMatches(currentTask, info: info) {
                            candidates.append(currentTask)
                        } else {
                            currentTask.cancel()
                        }
                    }

                    guard let retainedTask = candidates.max(by: {
                        $0.taskIdentifier < $1.taskIdentifier
                    }) else {
                        continue
                    }
                    for task in candidates
                        where task.taskIdentifier != retainedTask.taskIdentifier {
                        task.cancel()
                    }

                    info.task = retainedTask
                    self.activeDownloads[modelId] = info
                }
            }
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startDownload":
            guard let args = call.arguments as? [String: Any],
                  let modelId = args["modelId"] as? String,
                  let url = args["url"] as? String,
                  let destinationPath = args["destinationPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
                return
            }
            guard let downloadUrl = URL(string: url) else {
                result(FlutterError(code: "INVALID_URL", message: "Invalid URL", details: nil))
                return
            }

            // Create destination directory.
            let destDir = (destinationPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: destDir, withIntermediateDirectories: true, attributes: nil)

            // A manual restart supersedes both the current task and any
            // delayed automatic retry for this model.
            retryWorkItems.removeValue(forKey: modelId)?.cancel()
            retryGenerations.removeValue(forKey: modelId)
            activeDownloads[modelId]?.task?.cancel()

            var info = DownloadInfo(modelId: modelId, url: downloadUrl, destinationPath: destinationPath)
            startTask(&info)
            activeDownloads[modelId] = info
            persistDownloadRecord(info)
            result(true)

        case "cancelDownload":
            guard let args = call.arguments as? [String: Any],
                  let modelId = args["modelId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing modelId", details: nil))
                return
            }
            retryWorkItems.removeValue(forKey: modelId)?.cancel()
            retryGenerations.removeValue(forKey: modelId)
            let info = activeDownloads.removeValue(forKey: modelId)
                ?? restoredDownloadInfo(modelId)
            info?.task?.cancel()
            if let info = info {
                // A user cancel clears any saved resume data — a later download
                // starts fresh rather than silently resuming.
                clearResumeData(info.destinationPath)
            }
            removeDownloadRecord(modelId)

            // A background URLSession task may exist even when this process
            // has not yet reconstructed activeDownloads.
            session.getAllTasks { tasks in
                for task in tasks where task.taskDescription == modelId {
                    task.cancel()
                }
                DispatchQueue.main.async {
                    result(true)
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Build and resume the download task for `info`, preferring persisted
    /// resume data (continues a partial transfer) over a fresh download.
    private func startTask(_ info: inout DownloadInfo) {
        let task: URLSessionDownloadTask
        if let data = resumeData(for: info) {
            NSLog("BackgroundDownload: \(info.modelId) resuming from \(data.count) bytes of resume data")
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: info.url)
        }
        task.taskDescription = info.modelId
        info.task = task
        task.resume()
    }

    /// Schedule an auto-retry with exponential backoff (capped). Uses any
    /// freshly-saved resume data so the retry continues, not restarts.
    private func scheduleRetry(_ modelId: String) {
        guard var info = activeDownloads[modelId] else { return }
        info.retryCount += 1
        if info.retryCount > maxAutoRetries {
            NSLog("BackgroundDownload: \(modelId) exhausted \(maxAutoRetries) retries")
            channel.invokeMethod("onDownloadError", arguments: [
                "modelId": modelId,
                "error": "Network interrupted. Tap Download to resume.",
            ])
            retryWorkItems.removeValue(forKey: modelId)?.cancel()
            retryGenerations.removeValue(forKey: modelId)
            activeDownloads.removeValue(forKey: modelId)
            removeDownloadRecord(modelId)
            return
        }

        activeDownloads[modelId] = info
        persistDownloadRecord(info)
        let expectedRetryCount = info.retryCount
        let delay = min(pow(2.0, Double(expectedRetryCount)), 30.0) // 2,4,8,16,30,30s
        NSLog("BackgroundDownload: \(modelId) retry \(expectedRetryCount) in \(Int(delay))s")

        retryWorkItems.removeValue(forKey: modelId)?.cancel()
        let generation = UUID()
        retryGenerations[modelId] = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.retryGenerations[modelId] == generation else {
                return
            }
            self.retryWorkItems.removeValue(forKey: modelId)
            self.retryGenerations.removeValue(forKey: modelId)
            guard var current = self.activeDownloads[modelId],
                  current.retryCount == expectedRetryCount,
                  current.task == nil else {
                return
            }
            self.startTask(&current)
            self.activeDownloads[modelId] = current
        }
        retryWorkItems[modelId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let modelId = downloadTask.taskDescription else { return }

        let info: DownloadInfo
        if let current = activeDownloads[modelId] {
            guard current.task?.taskIdentifier == downloadTask.taskIdentifier else {
                NSLog("BackgroundDownload: \(modelId) ignored completion from superseded task")
                return
            }
            info = current
        } else if let restored = restoredDownloadInfo(modelId) {
            guard requestMatches(downloadTask, info: restored) else {
                downloadTask.cancel()
                NSLog("BackgroundDownload: \(modelId) ignored completion whose URL did not match persisted state")
                return
            }
            info = restored
        } else {
            NSLog("BackgroundDownload: \(modelId) finished but its persisted state is unavailable")
            channel.invokeMethod("onDownloadError", arguments: [
                "modelId": modelId,
                "error": "Download finished, but its destination information was unavailable.",
            ])
            return
        }

        let destURL = URL(fileURLWithPath: info.destinationPath)
        do {
            if FileManager.default.fileExists(atPath: info.destinationPath) {
                _ = try FileManager.default.replaceItemAt(
                    destURL,
                    withItemAt: location,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: location, to: destURL)
            }
            clearResumeData(info.destinationPath)

            let size = (try? FileManager.default.attributesOfItem(atPath: info.destinationPath)[.size] as? Int) ?? 0
            NSLog("BackgroundDownload: \(modelId) complete (\(size / 1024 / 1024) MB)")
            channel.invokeMethod("onDownloadComplete", arguments: [
                "modelId": modelId,
                "path": info.destinationPath,
                "size": size,
            ])
        } catch {
            NSLog("BackgroundDownload: \(modelId) move failed: \(error)")
            channel.invokeMethod("onDownloadError", arguments: [
                "modelId": modelId,
                "error": "Failed to save file: \(error.localizedDescription)",
            ])
        }
        retryWorkItems.removeValue(forKey: modelId)?.cancel()
        retryGenerations.removeValue(forKey: modelId)
        activeDownloads.removeValue(forKey: modelId)
        lastProgressEmit.removeValue(forKey: modelId)
        removeDownloadRecord(modelId)
    }

    /// Last progress emission per model, for throttling: URLSession fires
    /// didWriteData many times a second, and every callback was a
    /// main-thread platform-channel hop — a bridge storm for the whole
    /// duration of a multi-GB download.
    private var lastProgressEmit: [String: (fraction: Double, at: Date)] = [:]

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let modelId = downloadTask.taskDescription,
              let current = activeDownloads[modelId],
              current.task?.taskIdentifier == downloadTask.taskIdentifier else {
            return
        }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0
        let now = Date()
        if let last = lastProgressEmit[modelId],
           progress < 1.0,
           progress - last.fraction < 0.01,
           now.timeIntervalSince(last.at) < 0.3 {
            return
        }
        lastProgressEmit[modelId] = (progress, now)
        channel.invokeMethod("onDownloadProgress", arguments: [
            "modelId": modelId,
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
        guard let modelId = task.taskDescription else { return }
        guard let error = error else { return }  // success handled in didFinishDownloadingTo

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }  // user cancel — not an error

        var info: DownloadInfo
        if let current = activeDownloads[modelId] {
            guard current.task?.taskIdentifier == task.taskIdentifier else {
                NSLog("BackgroundDownload: \(modelId) ignored error from superseded task")
                return
            }
            info = current
        } else if let restored = restoredDownloadInfo(modelId) {
            guard requestMatches(task, info: restored) else {
                task.cancel()
                NSLog("BackgroundDownload: \(modelId) ignored error whose URL did not match persisted state")
                return
            }
            info = restored
        } else {
            channel.invokeMethod("onDownloadError", arguments: [
                "modelId": modelId,
                "error": "Download failed, and its persisted state was unavailable.",
            ])
            return
        }

        // The failed task is terminal. A retry work item may only start while
        // this slot remains taskless, which prevents delayed duplicate starts.
        info.task = nil
        activeDownloads[modelId] = info
        lastProgressEmit.removeValue(forKey: modelId)

        // Persist resume data with the URL it belongs to. If the server did
        // not provide usable data, discard both the blob and its metadata.
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           !data.isEmpty {
            persistResumeData(data, for: info)
            NSLog("BackgroundDownload: \(modelId) saved \(data.count) bytes resume data after error: \(error.localizedDescription)")
        } else {
            clearResumeData(info.destinationPath)
            NSLog("BackgroundDownload: \(modelId) error with no resume data: \(error.localizedDescription)")
        }
        scheduleRetry(modelId)
    }

    /// Background session finished delivering events while the app was
    /// suspended — let the system know we're done so it can snapshot the UI.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            (UIApplication.shared.delegate as? AppDelegate)?.backgroundSessionCompletionHandler?()
            (UIApplication.shared.delegate as? AppDelegate)?.backgroundSessionCompletionHandler = nil
        }
    }
}
