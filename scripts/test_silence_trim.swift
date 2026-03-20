#!/usr/bin/env swift

import AVFoundation
import Foundation

/// Analyze audio to find where speech starts and ends.
func detectSpeechRange(in asset: AVAsset) -> CMTimeRange? {
    guard let track = asset.tracks(withMediaType: .audio).first else {
        print("ERROR: No audio track found")
        return nil
    }

    let totalDuration = asset.duration
    let totalSeconds = CMTimeGetSeconds(totalDuration)
    print("Total duration: \(String(format: "%.1f", totalSeconds))s")
    if totalSeconds < 1.0 { return nil }

    guard let reader = try? AVAssetReader(asset: asset) else {
        print("ERROR: Can't create asset reader")
        return nil
    }
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

    let sampleRate = 44100.0
    let windowSamples = Int(sampleRate * 0.05) // 50ms
    var windowRMS: [Float] = []
    var sampleBuffer: [Int16] = []

    while let buffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let ptr = dataPointer else { continue }

        let int16Ptr = ptr.withMemoryRebound(to: Int16.self, capacity: length / 2) { $0 }
        let count = length / 2

        for i in 0..<count {
            sampleBuffer.append(int16Ptr[i])
            if sampleBuffer.count >= windowSamples {
                let rms = sqrt(sampleBuffer.reduce(Float(0)) { $0 + Float($1) * Float($1) / Float(windowSamples) })
                windowRMS.append(rms)
                sampleBuffer.removeAll(keepingCapacity: true)
            }
        }
    }
    reader.cancelReading()

    print("Analyzed \(windowRMS.count) windows (50ms each)")

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

    for i in 0..<windowRMS.count {
        if windowRMS[i] > threshold { firstSpeech = i; break }
    }
    for i in stride(from: windowRMS.count - 1, through: 0, by: -1) {
        if windowRMS[i] > threshold { lastSpeech = i; break }
    }

    let windowDuration = 0.05
    let paddingWindows = 3 // 150ms
    let rawFirstSpeech = firstSpeech
    let rawLastSpeech = lastSpeech
    firstSpeech = max(0, firstSpeech - paddingWindows)
    lastSpeech = min(windowRMS.count - 1, lastSpeech + paddingWindows)

    let speechStart = Double(firstSpeech) * windowDuration
    let speechEnd = Double(lastSpeech + 1) * windowDuration

    print("Speech detected: \(String(format: "%.2f", Double(rawFirstSpeech) * windowDuration))s - \(String(format: "%.2f", Double(rawLastSpeech + 1) * windowDuration))s")
    print("With padding:    \(String(format: "%.2f", speechStart))s - \(String(format: "%.2f", speechEnd))s")
    print("Would trim:      \(String(format: "%.2f", speechStart))s from start, \(String(format: "%.2f", totalSeconds - speechEnd))s from end")

    let trimmedStart = speechStart
    let trimmedEnd = totalSeconds - speechEnd
    if trimmedStart + trimmedEnd < 0.3 {
        print("Less than 300ms to trim — skipping")
        return nil
    }

    let startTime = CMTime(seconds: speechStart, preferredTimescale: 1000)
    let endTime = CMTime(seconds: speechEnd, preferredTimescale: 1000)
    return CMTimeRange(start: startTime, end: endTime)
}

// MARK: - Main

guard CommandLine.arguments.count > 1 else {
    print("Usage: swift test_silence_trim.swift <audio_file.m4a>")
    print("  Downloads from Supabase if URL provided")
    exit(1)
}

let path = CommandLine.arguments[1]
let url: URL

if path.hasPrefix("http") {
    // Download from URL first
    print("Downloading from URL...")
    let tempPath = "/tmp/test_audio_trim.m4a"
    let data = try! Data(contentsOf: URL(string: path)!)
    try! data.write(to: URL(fileURLWithPath: tempPath))
    url = URL(fileURLWithPath: tempPath)
    print("Downloaded \(data.count / 1024)KB")
} else {
    url = URL(fileURLWithPath: path)
}

print("Analyzing: \(url.lastPathComponent)")
print("---")

let asset = AVAsset(url: url)
if let range = detectSpeechRange(in: asset) {
    print("---")
    print("✓ Would trim to: \(String(format: "%.2f", CMTimeGetSeconds(range.start)))s - \(String(format: "%.2f", CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))))s")

    // Actually do the trim as a test
    let outputPath = "/tmp/trimmed_output.m4a"
    try? FileManager.default.removeItem(atPath: outputPath)

    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        print("ERROR: Can't create export session")
        exit(1)
    }
    exportSession.outputURL = URL(fileURLWithPath: outputPath)
    exportSession.outputFileType = .m4a
    exportSession.timeRange = range

    let semaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        if exportSession.status == .completed {
            let origSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let trimSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
            print("✓ Exported trimmed file: \(trimSize / 1024)KB (was \(origSize / 1024)KB)")
            print("  Output: \(outputPath)")
        } else {
            print("✗ Export failed: \(exportSession.error?.localizedDescription ?? "unknown")")
        }
        semaphore.signal()
    }
    semaphore.wait()
} else {
    print("---")
    print("No significant silence to trim")
}
