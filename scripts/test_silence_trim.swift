#!/usr/bin/env swift

import AVFoundation
import Foundation

struct DiagnosticFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Analyze audio to find where speech starts and ends.
func detectSpeechRange(in asset: AVAsset) throws -> CMTimeRange? {
    guard let track = asset.tracks(withMediaType: .audio).first else {
        throw DiagnosticFailure(message: "No audio track found")
    }
    guard let formatDescription = track.formatDescriptions.first as? CMAudioFormatDescription,
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
        throw DiagnosticFailure(message: "Can't read the audio stream format")
    }

    let sampleRate = streamDescription.mSampleRate
    let channelCount = Int(streamDescription.mChannelsPerFrame)
    guard sampleRate > 0, channelCount > 0 else {
        throw DiagnosticFailure(message: "Invalid audio format: \(sampleRate) Hz, \(channelCount) channels")
    }

    let totalSeconds = CMTimeGetSeconds(asset.duration)
    print("Total duration: \(String(format: "%.1f", totalSeconds))s")
    if totalSeconds < 1.0 { return nil }

    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        throw DiagnosticFailure(message: "Can't create asset reader: \(error.localizedDescription)")
    }
    let outputSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    guard reader.canAdd(output) else {
        throw DiagnosticFailure(message: "Can't add the PCM reader output")
    }
    reader.add(output)
    guard reader.startReading() else {
        throw DiagnosticFailure(
            message: "Audio reader failed to start: \(reader.error?.localizedDescription ?? "unknown error")"
        )
    }

    let targetWindowDuration = 0.05
    let windowFrames = max(1, Int((sampleRate * targetWindowDuration).rounded()))
    let windowDuration = Double(windowFrames) / sampleRate
    var windowRMS: [Float] = []
    var framesInWindow = 0
    var squaredSum: Float = 0

    while let buffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            throw DiagnosticFailure(message: "Couldn't read decoded PCM data")
        }

        let sampleCount = length / MemoryLayout<Int16>.size
        pointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
            let frameCount = sampleCount / channelCount
            for frame in 0..<frameCount {
                var frameSquaredSum: Float = 0
                let frameStart = frame * channelCount
                for channel in 0..<channelCount {
                    let sample = Float(samples[frameStart + channel])
                    frameSquaredSum += sample * sample
                }
                squaredSum += frameSquaredSum / Float(channelCount)
                framesInWindow += 1
                if framesInWindow == windowFrames {
                    windowRMS.append(sqrt(squaredSum / Float(windowFrames)))
                    squaredSum = 0
                    framesInWindow = 0
                }
            }
        }
    }

    if reader.status == .failed {
        throw DiagnosticFailure(
            message: "Audio decoding failed: \(reader.error?.localizedDescription ?? "unknown error")"
        )
    }
    guard reader.status == .completed else {
        throw DiagnosticFailure(message: "Audio decoding ended with status \(reader.status.rawValue)")
    }

    print(
        "Analyzed \(windowRMS.count) windows " +
        "(\(String(format: "%.1f", windowDuration * 1000))ms each, " +
        "\(String(format: "%.0f", sampleRate)) Hz, \(channelCount) channel(s))"
    )
    if windowRMS.isEmpty { return nil }

    let peakRMS = windowRMS.max() ?? 0
    let threshold = peakRMS * 0.05
    print("Peak RMS: \(String(format: "%.0f", peakRMS)), threshold: \(String(format: "%.0f", threshold))")
    if threshold < 10 {
        print("Entire recording appears silent")
        return nil
    }

    var firstSpeech = 0
    var lastSpeech = windowRMS.count - 1
    for index in 0..<windowRMS.count where windowRMS[index] > threshold {
        firstSpeech = index
        break
    }
    for index in stride(from: windowRMS.count - 1, through: 0, by: -1)
        where windowRMS[index] > threshold {
        lastSpeech = index
        break
    }

    let paddingWindows = Int(ceil(0.15 / windowDuration))
    let rawFirstSpeech = firstSpeech
    let rawLastSpeech = lastSpeech
    firstSpeech = max(0, firstSpeech - paddingWindows)
    lastSpeech = min(windowRMS.count - 1, lastSpeech + paddingWindows)

    let speechStart = Double(firstSpeech) * windowDuration
    let speechEnd = Double(lastSpeech + 1) * windowDuration
    print("Speech detected: \(String(format: "%.2f", Double(rawFirstSpeech) * windowDuration))s - \(String(format: "%.2f", Double(rawLastSpeech + 1) * windowDuration))s")
    print("With padding:    \(String(format: "%.2f", speechStart))s - \(String(format: "%.2f", speechEnd))s")
    print("Would trim:      \(String(format: "%.2f", speechStart))s from start, \(String(format: "%.2f", totalSeconds - speechEnd))s from end")

    if speechStart + totalSeconds - speechEnd < 0.3 {
        print("Less than 300ms to trim — skipping")
        return nil
    }

    let startTime = CMTime(seconds: speechStart, preferredTimescale: 1000)
    let endTime = CMTime(seconds: speechEnd, preferredTimescale: 1000)
    return CMTimeRange(start: startTime, end: endTime)
}

final class DownloadState: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}

func download(_ url: URL) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    let state = DownloadState()
    let task = URLSession.shared.dataTask(with: url) { data, response, error in
        state.data = data
        state.response = response
        state.error = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    if let error = state.error {
        throw DiagnosticFailure(message: "Download failed: \(error.localizedDescription)")
    }
    guard let httpResponse = state.response as? HTTPURLResponse else {
        throw DiagnosticFailure(message: "Download returned no HTTP response")
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
        throw DiagnosticFailure(message: "Download returned HTTP \(httpResponse.statusCode)")
    }
    guard let data = state.data else {
        throw DiagnosticFailure(message: "Download returned no data")
    }
    return data
}

func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw DiagnosticFailure(
            message: "Usage: swift test_silence_trim.swift <audio_file.m4a-or-URL>"
        )
    }

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("castcircle_silence_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let input = CommandLine.arguments[1]
    let inputURL: URL
    if input.lowercased().hasPrefix("http") {
        guard let remoteURL = URL(string: input),
              let scheme = remoteURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              remoteURL.host != nil else {
            throw DiagnosticFailure(message: "Invalid HTTP URL: \(input)")
        }
        print("Downloading from URL...")
        let data = try download(remoteURL)
        inputURL = temporaryDirectory.appendingPathComponent("input.m4a")
        do {
            try data.write(to: inputURL, options: .atomic)
        } catch {
            throw DiagnosticFailure(message: "Can't write downloaded audio: \(error.localizedDescription)")
        }
        print("Downloaded \(data.count / 1024)KB")
    } else {
        inputURL = URL(fileURLWithPath: input)
    }

    print("Analyzing: \(inputURL.lastPathComponent)")
    print("---")
    let asset = AVAsset(url: inputURL)
    guard let range = try detectSpeechRange(in: asset) else {
        print("---")
        print("No significant silence to trim")
        return
    }

    print("---")
    print("Would trim to: \(String(format: "%.2f", CMTimeGetSeconds(range.start)))s - \(String(format: "%.2f", CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))))s")

    let outputURL = temporaryDirectory.appendingPathComponent("trimmed_output.m4a")
    guard let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetAppleM4A
    ) else {
        throw DiagnosticFailure(message: "Can't create export session")
    }
    exportSession.outputURL = outputURL
    exportSession.outputFileType = .m4a
    exportSession.timeRange = range

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously { semaphore.signal() }
    semaphore.wait()
    guard exportSession.status == .completed else {
        throw DiagnosticFailure(
            message: "Export failed: \(exportSession.error?.localizedDescription ?? "unknown error")"
        )
    }

    let originalSize = (try? FileManager.default.attributesOfItem(
        atPath: inputURL.path
    )[.size] as? Int) ?? 0
    let trimmedSize = (try? FileManager.default.attributesOfItem(
        atPath: outputURL.path
    )[.size] as? Int) ?? 0
    print("Exported trimmed file: \(trimmedSize / 1024)KB (was \(originalSize / 1024)KB)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(
        "ERROR: \(error.localizedDescription)\n".data(using: .utf8)!
    )
    exit(1)
}
