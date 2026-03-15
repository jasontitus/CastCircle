import Flutter
import UIKit

/// Native iOS plugin for background file downloads using URLSession.
///
/// Uses a background URLSession configuration so downloads survive
/// screen sleep, app suspension, and even app termination.
class BackgroundDownloadPlugin: NSObject, URLSessionDownloadDelegate {
    static let channelName = "com.lineguide/background_download"

    private let channel: FlutterMethodChannel
    private var session: URLSession!
    private var activeDownloads: [String: DownloadInfo] = [:]

    struct DownloadInfo {
        let modelId: String
        let destinationPath: String
        var task: URLSessionDownloadTask?
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

            // Clean up any existing .tmp file
            let tmpPath = destinationPath + ".tmp"
            try? FileManager.default.removeItem(atPath: tmpPath)

            // Create destination directory
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

            // Cancel any existing download for this model
            if let existing = activeDownloads[modelId] {
                existing.task?.cancel()
            }

            let task = session.downloadTask(with: downloadUrl)
            activeDownloads[modelId] = DownloadInfo(
                modelId: modelId,
                destinationPath: destinationPath,
                task: task
            )
            task.taskDescription = modelId
            task.resume()

            result(true)

        case "cancelDownload":
            guard let args = call.arguments as? [String: Any],
                  let modelId = args["modelId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing modelId", details: nil))
                return
            }
            if let info = activeDownloads.removeValue(forKey: modelId) {
                info.task?.cancel()
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
        guard let modelId = downloadTask.taskDescription,
              let info = activeDownloads[modelId] else { return }

        let destURL = URL(fileURLWithPath: info.destinationPath)

        do {
            // Remove existing file if present
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: location, to: destURL)

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

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0.0
        }

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

        if let error = error {
            let nsError = error as NSError
            // Don't report cancellation as an error
            if nsError.code == NSURLErrorCancelled { return }

            NSLog("BackgroundDownload: \(modelId) error: \(error)")
            channel.invokeMethod("onDownloadError", arguments: [
                "modelId": modelId,
                "error": error.localizedDescription,
            ])
        }

        activeDownloads.removeValue(forKey: modelId)
    }
}
