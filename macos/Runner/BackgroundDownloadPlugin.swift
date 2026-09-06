import FlutterMacOS

/// macOS native plugin for file downloads using URLSession.
class BackgroundDownloadPlugin: NSObject, URLSessionDownloadDelegate {
    static let channelName = "com.lineguide/background_download"

    private let channel: FlutterMethodChannel
    private var session: URLSession!
    private var activeDownloads: [Int: DownloadInfo] = [:]
    private var activeTaskByModelId: [String: Int] = [:]
    private var lastProgressEmit: [Int: (fraction: Double, at: Date)] = [:]

    struct DownloadInfo {
        let modelId: String
        let destinationPath: String
        let task: URLSessionDownloadTask
    }

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()

        // Use default session on macOS (background sessions not needed for desktop)
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        channel.setMethodCallHandler(handle)
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

            let destDir = (destinationPath as NSString).deletingLastPathComponent

            try? FileManager.default.createDirectory(
                atPath: destDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            guard let downloadUrl = URL(string: url) else {
                result(FlutterError(code: "INVALID_URL", message: "Invalid URL", details: nil))
                return
            }

            if let existingTaskId = activeTaskByModelId[modelId] {
                activeDownloads[existingTaskId]?.task.cancel()
            }

            let task = session.downloadTask(with: downloadUrl)
            let taskId = task.taskIdentifier
            activeDownloads[taskId] = DownloadInfo(
                modelId: modelId,
                destinationPath: destinationPath,
                task: task
            )
            activeTaskByModelId[modelId] = taskId
            task.resume()

            result(true)

        case "cancelDownload":
            guard let args = call.arguments as? [String: Any],
                  let modelId = args["modelId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing modelId", details: nil))
                return
            }
            if let taskId = activeTaskByModelId.removeValue(forKey: modelId) {
                activeDownloads[taskId]?.task.cancel()
            }
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        guard let info = activeDownloads[taskId],
              activeTaskByModelId[info.modelId] == taskId else { return }

        let modelId = info.modelId
        let destURL = URL(fileURLWithPath: info.destinationPath)
        let stagingURL = destURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destURL.lastPathComponent).\(UUID().uuidString).tmp"
        )

        defer {
            try? FileManager.default.removeItem(at: stagingURL)
            removeDownload(taskId: taskId, modelId: modelId)
        }

        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            if FileManager.default.fileExists(atPath: destURL.path) {
                _ = try FileManager.default.replaceItemAt(destURL, withItemAt: stagingURL)
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: destURL)
            }

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

    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        guard let info = activeDownloads[taskId],
              activeTaskByModelId[info.modelId] == taskId else { return }
        let modelId = info.modelId

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0.0
        }

        // Throttle: URLSession fires this many times a second and the
        // delegate queue is main — unthrottled, a multi-hundred-MB model
        // download was a main-thread platform-channel storm (iOS twin has
        // the same guard).
        let now = Date()
        if let last = lastProgressEmit[taskId],
           progress < 1.0,
           progress - last.fraction < 0.01,
           now.timeIntervalSince(last.at) < 0.3 {
            return
        }
        lastProgressEmit[taskId] = (progress, now)

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
        let taskId = task.taskIdentifier
        guard let info = activeDownloads[taskId] else { return }
        let modelId = info.modelId
        let isCurrent = activeTaskByModelId[modelId] == taskId

        defer { removeDownload(taskId: taskId, modelId: modelId) }

        guard isCurrent, let error = error else { return }

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }

        NSLog("BackgroundDownload: \(modelId) error: \(error)")
        channel.invokeMethod("onDownloadError", arguments: [
            "modelId": modelId,
            "error": error.localizedDescription,
        ])
    }

    private func removeDownload(taskId: Int, modelId: String) {
        activeDownloads.removeValue(forKey: taskId)
        lastProgressEmit.removeValue(forKey: taskId)
        if activeTaskByModelId[modelId] == taskId {
            activeTaskByModelId.removeValue(forKey: modelId)
        }
    }
}
