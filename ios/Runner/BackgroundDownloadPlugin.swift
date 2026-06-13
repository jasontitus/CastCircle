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
    }

    /// Where the resume-data blob for a download is persisted. Keyed off the
    /// destination so it survives app relaunch and a fresh plugin instance.
    private func resumePath(_ destinationPath: String) -> String {
        destinationPath + ".resume"
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

            // Cancel any in-flight download for this model first.
            if let existing = activeDownloads[modelId] {
                existing.task?.cancel()
            }

            var info = DownloadInfo(modelId: modelId, url: downloadUrl, destinationPath: destinationPath)
            startTask(&info)
            activeDownloads[modelId] = info
            result(true)

        case "cancelDownload":
            guard let args = call.arguments as? [String: Any],
                  let modelId = args["modelId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing modelId", details: nil))
                return
            }
            if let info = activeDownloads.removeValue(forKey: modelId) {
                info.task?.cancel()
                // A user cancel clears any saved resume data — a later download
                // starts fresh rather than silently resuming.
                try? FileManager.default.removeItem(atPath: resumePath(info.destinationPath))
            }
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Build and resume the download task for `info`, preferring persisted
    /// resume data (continues a partial transfer) over a fresh download.
    private func startTask(_ info: inout DownloadInfo) {
        let task: URLSessionDownloadTask
        let resumeFile = resumePath(info.destinationPath)
        if let resumeData = try? Data(contentsOf: URL(fileURLWithPath: resumeFile)),
           !resumeData.isEmpty {
            NSLog("BackgroundDownload: \(info.modelId) resuming from \(resumeData.count) bytes of resume data")
            task = session.downloadTask(withResumeData: resumeData)
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
            activeDownloads.removeValue(forKey: modelId)
            return
        }
        activeDownloads[modelId] = info
        let delay = min(pow(2.0, Double(info.retryCount)), 30.0) // 2,4,8,16,30,30s
        NSLog("BackgroundDownload: \(modelId) retry \(info.retryCount) in \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, var info = self.activeDownloads[modelId] else { return }
            self.startTask(&info)
            self.activeDownloads[modelId] = info
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let modelId = downloadTask.taskDescription,
              let info = activeDownloads[modelId] else { return }

        let destURL = URL(fileURLWithPath: info.destinationPath)
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: location, to: destURL)
            // Success — clear any resume data.
            try? FileManager.default.removeItem(atPath: resumePath(info.destinationPath))

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
        activeDownloads.removeValue(forKey: modelId)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let modelId = downloadTask.taskDescription else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0
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

        guard let info = activeDownloads[modelId] else { return }

        // Persist resume data so the retry (or a later manual one) continues
        // from the bytes already on disk. If the server didn't give us resume
        // data, drop any stale blob so the next attempt restarts cleanly.
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: URL(fileURLWithPath: resumePath(info.destinationPath)))
            NSLog("BackgroundDownload: \(modelId) saved \(resumeData.count) bytes resume data after error: \(error.localizedDescription)")
        } else {
            try? FileManager.default.removeItem(atPath: resumePath(info.destinationPath))
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
