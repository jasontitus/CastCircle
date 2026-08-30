#!/usr/bin/env swift

import AVFoundation
import Foundation

private enum SilenceTrimError: LocalizedError {
    case noAudioTrack
    case invalidAudioFormat
    case unsupportedAudioFormat(String)
    case reader(String)
    case malformedRemoteURL(String)
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "no audio track found"
        case .invalidAudioFormat:
            return "decoded audio has no valid stream format"
        case let .unsupportedAudioFormat(description):
            return "unsupported decoded audio format: \(description)"
        case let .reader(description):
            return "audio reader failed: \(description)"
        case let .malformedRemoteURL(value):
            return "invalid HTTP(S) URL: \(value)"
        case let .httpStatus(status):
            return "download returned HTTP \(status)"
        case .emptyResponse:
            return "download completed without response data"
        }
    }
}

private final class TemporaryDirectoryCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?

    func register(_ directory: URL) {
        lock.lock()
        self.directory = directory
        lock.unlock()
    }

    func removeRegisteredDirectory() {
        lock.lock()
        let directory = self.directory
        self.directory = nil
        lock.unlock()
        guard let directory else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            let warning = "WARNING: remove temporary directory: "
                + "\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }
}

private let temporaryDirectoryCleanup = TemporaryDirectoryCleanup()

private func fail(_ operation: String, _ error: Error? = nil) -> Never {
    let detail = error.map { ": \($0.localizedDescription)" } ?? ""
    FileHandle.standardError.write(Data("ERROR: \(operation)\(detail)\n".utf8))
    temporaryDirectoryCleanup.removeRegisteredDirectory()
    exit(1)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "castcircle-silence-trim-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    return directory
}

private final class DownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func takeResult() -> Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private func download(_ remoteURL: URL) throws -> Data {
    let state = DownloadState()
    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: remoteURL) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            state.finish(.failure(error))
            return
        }
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            state.finish(.failure(SilenceTrimError.httpStatus(response.statusCode)))
            return
        }
        guard let data else {
            state.finish(.failure(SilenceTrimError.emptyResponse))
            return
        }
        state.finish(.success(data))
    }
    task.resume()
    semaphore.wait()

    guard let result = state.takeResult() else {
        throw SilenceTrimError.emptyResponse
    }
    return try result.get()
}

/// Analyze audio to find where speech starts and ends.
func detectSpeechRange(in asset: AVAsset) throws -> CMTimeRange? {
    guard let track = asset.tracks(withMediaType: .audio).first else {
        throw SilenceTrimError.noAudioTrack
    }

    let totalDuration = asset.duration
    let totalSeconds = CMTimeGetSeconds(totalDuration)
    print("Total duration: \(String(format: "%.1f", totalSeconds))s")
    if totalSeconds < 1.0 { return nil }

    let reader = try AVAssetReader(asset: asset)
    let outputSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    guard reader.canAdd(output) else {
        throw SilenceTrimError.reader("cannot add decoded PCM output")
    }
    reader.add(output)
    guard reader.startReading() else {
        throw SilenceTrimError.reader(reader.error?.localizedDescription ?? "cannot start")
    }

    var sampleRate: Double?
    var channelCount = 0
    var windowFrames = 0
    var framesInWindow = 0
    var samplesInWindow = 0
    var sumOfSquares = 0.0
    var windowRMS: [Double] = []

    while let buffer = output.copyNextSampleBuffer() {
        guard let formatDescription = CMSampleBufferGetFormatDescription(buffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              ) else {
            throw SilenceTrimError.invalidAudioFormat
        }

        let bufferRate = streamDescription.pointee.mSampleRate
        let bufferChannels = Int(streamDescription.pointee.mChannelsPerFrame)
        guard bufferRate.isFinite, bufferRate > 0, bufferChannels > 0 else {
            throw SilenceTrimError.invalidAudioFormat
        }
        if let sampleRate {
            guard abs(sampleRate - bufferRate) < 0.5,
                  channelCount == bufferChannels else {
                throw SilenceTrimError.unsupportedAudioFormat(
                    "format changes between sample buffers"
                )
            }
        } else {
            sampleRate = bufferRate
            channelCount = bufferChannels
            windowFrames = max(1, Int((bufferRate * 0.05).rounded()))
            print(
                "Decoded format: \(String(format: "%.0f", bufferRate)) Hz, "
                    + "\(bufferChannels) channel(s)"
            )
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard pointerStatus == kCMBlockBufferNoErr, let dataPointer else {
            throw SilenceTrimError.reader("decoded PCM buffer is not contiguous")
        }

        let availableSamples = length / MemoryLayout<Int16>.size
        let availableFrames = availableSamples / channelCount
        let declaredFrames = CMSampleBufferGetNumSamples(buffer)
        let frameCount = min(availableFrames, declaredFrames)
        let samples = dataPointer.withMemoryRebound(
            to: Int16.self,
            capacity: availableSamples
        ) { $0 }

        for frameIndex in 0..<frameCount {
            let firstSample = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                let sample = Double(samples[firstSample + channelIndex])
                sumOfSquares += sample * sample
                samplesInWindow += 1
            }
            framesInWindow += 1
            if framesInWindow == windowFrames {
                windowRMS.append(sqrt(sumOfSquares / Double(samplesInWindow)))
                framesInWindow = 0
                samplesInWindow = 0
                sumOfSquares = 0
            }
        }
    }

    if reader.status == .failed {
        throw SilenceTrimError.reader(reader.error?.localizedDescription ?? "decode failed")
    }
    guard let sampleRate else {
        throw SilenceTrimError.invalidAudioFormat
    }

    let windowDuration = Double(windowFrames) / sampleRate
    print(
        "Analyzed \(windowRMS.count) windows "
            + "(\(String(format: "%.1f", windowDuration * 1000))ms each)"
    )
    if windowRMS.isEmpty { return nil }

    let peakRMS = windowRMS.max() ?? 0
    let threshold = peakRMS * 0.05
    print(
        "Peak RMS: \(String(format: "%.0f", peakRMS)), "
            + "threshold: \(String(format: "%.0f", threshold))"
    )
    if threshold < 10 {
        print("Entire recording appears silent")
        return nil
    }

    var firstSpeech = windowRMS.firstIndex { $0 > threshold } ?? 0
    var lastSpeech = windowRMS.lastIndex { $0 > threshold } ?? (windowRMS.count - 1)
    let rawFirstSpeech = firstSpeech
    let rawLastSpeech = lastSpeech
    let paddingWindows = max(1, Int((0.15 / windowDuration).rounded()))
    firstSpeech = max(0, firstSpeech - paddingWindows)
    lastSpeech = min(windowRMS.count - 1, lastSpeech + paddingWindows)

    let speechStart = Double(firstSpeech) * windowDuration
    let speechEnd = min(totalSeconds, Double(lastSpeech + 1) * windowDuration)
    print(
        "Speech detected: \(String(format: "%.2f", Double(rawFirstSpeech) * windowDuration))s"
            + " - \(String(format: "%.2f", Double(rawLastSpeech + 1) * windowDuration))s"
    )
    print(
        "With padding:    \(String(format: "%.2f", speechStart))s"
            + " - \(String(format: "%.2f", speechEnd))s"
    )
    print(
        "Would trim:      \(String(format: "%.2f", speechStart))s from start, "
            + "\(String(format: "%.2f", totalSeconds - speechEnd))s from end"
    )

    let trimmedStart = speechStart
    let trimmedEnd = totalSeconds - speechEnd
    if trimmedStart + trimmedEnd < 0.3 {
        print("Less than 300ms to trim — skipping")
        return nil
    }

    let startTime = CMTime(seconds: speechStart, preferredTimescale: 1_000_000)
    let endTime = CMTime(seconds: speechEnd, preferredTimescale: 1_000_000)
    return CMTimeRange(start: startTime, end: endTime)
}

private func parseArguments() -> (input: String, keepOutput: URL?) {
    var input: String?
    var keepOutput: URL?
    var index = 1
    while index < CommandLine.arguments.count {
        let argument = CommandLine.arguments[index]
        if argument == "--keep-output" {
            guard index + 1 < CommandLine.arguments.count else {
                fail("--keep-output requires a file path")
            }
            keepOutput = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            index += 2
            continue
        }
        guard !argument.hasPrefix("--") else {
            fail("unknown option \(argument)")
        }
        guard input == nil else {
            fail("only one audio input may be provided")
        }
        input = argument
        index += 1
    }

    guard let input else {
        print("Usage: swift test_silence_trim.swift <audio-file-or-URL> [--keep-output <path>]")
        exit(1)
    }
    return (input, keepOutput)
}

private func fileSize(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.size] as? Int ?? 0
}

let arguments = parseArguments()
let temporaryDirectory: URL
do {
    temporaryDirectory = try makeTemporaryDirectory()
} catch {
    fail("create unique temporary directory", error)
}
temporaryDirectoryCleanup.register(temporaryDirectory)

let inputURL: URL
if arguments.input.lowercased().hasPrefix("http") {
    guard let remoteURL = URL(string: arguments.input),
          let scheme = remoteURL.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          remoteURL.host != nil else {
        fail("validate remote input", SilenceTrimError.malformedRemoteURL(arguments.input))
    }
    print("Downloading from URL...")
    let data: Data
    do {
        data = try download(remoteURL)
    } catch {
        fail("download \(remoteURL.absoluteString)", error)
    }
    let remoteExtension = remoteURL.pathExtension
    let remoteFilename = remoteExtension.isEmpty
        ? "remote-input"
        : "remote-input.\(remoteExtension)"
    let downloadedURL = temporaryDirectory.appendingPathComponent(remoteFilename)
    do {
        try data.write(to: downloadedURL, options: .atomic)
    } catch {
        fail("write downloaded input", error)
    }
    inputURL = downloadedURL
    print("Downloaded \(data.count / 1024)KB")
} else {
    inputURL = URL(fileURLWithPath: arguments.input)
}

print("Analyzing: \(inputURL.lastPathComponent)")
print("---")

let asset = AVAsset(url: inputURL)
let range: CMTimeRange?
do {
    range = try detectSpeechRange(in: asset)
} catch {
    fail("analyze audio", error)
}

if let range {
    print("---")
    let rangeEnd = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
    print(
        "✓ Would trim to: \(String(format: "%.2f", CMTimeGetSeconds(range.start)))s"
            + " - \(String(format: "%.2f", rangeEnd))s"
    )

    let temporaryOutputURL = temporaryDirectory.appendingPathComponent("trimmed-output.m4a")
    guard let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetAppleM4A
    ) else {
        fail("create export session")
    }
    exportSession.outputURL = temporaryOutputURL
    exportSession.outputFileType = .m4a
    exportSession.timeRange = range

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        semaphore.signal()
    }
    semaphore.wait()
    guard exportSession.status == .completed else {
        fail("export trimmed audio", exportSession.error)
    }

    var finalOutputURL = temporaryOutputURL
    if let keepOutput = arguments.keepOutput {
        guard !FileManager.default.fileExists(atPath: keepOutput.path) else {
            fail("keep output; destination already exists: \(keepOutput.path)")
        }
        do {
            try FileManager.default.moveItem(at: temporaryOutputURL, to: keepOutput)
        } catch {
            fail("keep exported output at \(keepOutput.path)", error)
        }
        finalOutputURL = keepOutput
    }

    do {
        let originalSize = try fileSize(at: inputURL)
        let trimmedSize = try fileSize(at: finalOutputURL)
        print(
            "✓ Exported trimmed file: \(trimmedSize / 1024)KB "
                + "(was \(originalSize / 1024)KB)"
        )
    } catch {
        fail("read exported file metadata", error)
    }
    if arguments.keepOutput != nil {
        print("  Output: \(finalOutputURL.path)")
    } else {
        print("  Temporary output verified and removed on exit")
    }
} else {
    print("---")
    print("No significant silence to trim")
}
temporaryDirectoryCleanup.removeRegisteredDirectory()
