import AVFoundation
import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
    func testContactPickerGateRejectsOverlapAndResolvesOnce() {
        let gate = ContactPickerResultGate()
        var firstResults = 0
        var secondResults = 0

        XCTAssertTrue(gate.begin { _ in firstResults += 1 })
        XCTAssertFalse(gate.begin { _ in secondResults += 1 })
        gate.resolve(["name": "Taylor"])
        gate.resolve(nil)

        XCTAssertEqual(firstResults, 1)
        XCTAssertEqual(secondResults, 0)
        XCTAssertFalse(gate.isActive)
    }

    func testRecordingRingDrainsBySequenceAfterSlotRecycle() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 8_000,
            channels: 1
        ))
        let slots = try (0..<3).map { _ in
            RecordingBufferSlot(buffer: try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 16
            )))
        }

        // Slot zero was recycled while older buffers remained ready.
        slots[0].state = 1
        slots[0].enqueueSequence = 3
        slots[1].state = 1
        slots[1].enqueueSequence = 1
        slots[2].state = 1
        slots[2].enqueueSequence = 2

        XCTAssertTrue(oldestReadyRecordingSlot(in: slots) === slots[1])
        slots[1].state = 2
        XCTAssertTrue(oldestReadyRecordingSlot(in: slots) === slots[2])
        slots[2].state = 0
        XCTAssertTrue(oldestReadyRecordingSlot(in: slots) === slots[0])
    }

    func testRecordingDrainsOversizedTapBufferBeforeClosingCAF() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cafURL = directory.appendingPathComponent("oversized-tap.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let pipeline = RealtimeRecordingPipeline()
        XCTAssertTrue(pipeline.prepare(format: format, frameCapacity: 4_096))
        let file = try AVAudioFile(
            forWriting: cafURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        XCTAssertTrue(pipeline.start(file: file, cafURL: cafURL))

        // The tap's minimum supported duration (100ms at 48kHz) exceeds
        // the requested 4096 frames. Neither channel may be dropped/truncated.
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_800
        ))
        buffer.frameLength = 4_800
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<4_800 {
            samples[0][frame] = Float(frame) / 4_800
            samples[1][frame] = -Float(frame) / 4_800
        }
        pipeline.enqueue(buffer)

        let finished = expectation(description: "CAF drained and finalized")
        XCTAssertTrue(pipeline.finish { capture in
            defer { finished.fulfill() }
            XCTAssertNil(capture.writeError)
            do {
                let recorded = try AVAudioFile(forReading: capture.cafURL)
                XCTAssertEqual(recorded.length, 4_800)
                let decoded = try XCTUnwrap(AVAudioPCMBuffer(
                    pcmFormat: recorded.processingFormat,
                    frameCapacity: 4_800
                ))
                try recorded.read(into: decoded)
                XCTAssertEqual(decoded.frameLength, 4_800)
                let actual = try XCTUnwrap(decoded.floatChannelData)
                for frame in 0..<Int(decoded.frameLength) {
                    XCTAssertEqual(actual[0][frame], samples[0][frame])
                    XCTAssertEqual(actual[1][frame], samples[1][frame])
                }
            } catch {
                XCTFail("Could not read finalized capture: \(error)")
            }
        })
        // Finalization must not depend on ARC releasing every writer reference.
        withExtendedLifetime((file, pipeline, buffer)) {
            wait(for: [finished], timeout: 5)
        }
    }

    func testKokoroRequestGateKeepsSiblingsAndCancelsOnlyOlderGroups() {
        let gate = KokoroRequestGate()

        XCTAssertTrue(gate.register(group: "prefetch-a", urgent: false))
        XCTAssertTrue(gate.register(group: "prefetch-a", urgent: false))
        XCTAssertTrue(gate.register(group: "prefetch-b", urgent: false))

        XCTAssertTrue(gate.register(group: "speak-c", urgent: true))
        XCTAssertFalse(gate.isActive("prefetch-a"))
        XCTAssertFalse(gate.isActive("prefetch-b"))
        XCTAssertTrue(gate.isActive("speak-c"))
        XCTAssertTrue(gate.register(group: "prefetch-d", urgent: false))
        XCTAssertTrue(gate.register(group: "speak-c", urgent: true))
        XCTAssertTrue(gate.isActive("prefetch-d"))

        XCTAssertFalse(gate.register(group: "prefetch-a", urgent: false))
    }

    func testAtomicReplacementPreservesOldFileOnFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("take.m4a")
        let missingTemporary = directory.appendingPathComponent("missing.m4a")
        try Data("known-good".utf8).write(to: destination)

        XCTAssertNotNil(AppleSttPlugin.atomicallyReplace(
            temporaryURL: missingTemporary,
            destinationURL: destination
        ))
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("known-good".utf8)
        )

        let replacement = directory.appendingPathComponent("replacement.m4a")
        try Data("new-take".utf8).write(to: replacement)
        XCTAssertNil(AppleSttPlugin.atomicallyReplace(
            temporaryURL: replacement,
            destinationURL: destination
        ))
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("new-take".utf8)
        )
    }

    func testChunkedLoudnessMatchesKnownStereoSignal() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("long-stereo.caf")
        try writePCM(
            to: url,
            channels: 2,
            frameCount: 100_000
        ) { frame in
            frame.isMultiple(of: 2) ? 0.25 : -0.25
        }

        let measurement = try XCTUnwrap(
            AudioAnalysisPlugin.measureLoudness(at: url)
        )
        XCTAssertEqual(measurement.rmsDbfs, 20 * log10(0.25), accuracy: 0.001)
        XCTAssertEqual(measurement.peakDbfs, 20 * log10(0.25), accuracy: 0.001)
    }

    func testSpeechTrimUsesFramesForMonoAndStereo() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monoURL = directory.appendingPathComponent("mono.caf")
        let stereoURL = directory.appendingPathComponent("stereo.caf")
        let signal: (Int) -> Float = { frame in
            (3_200..<11_200).contains(frame) ? 0.5 : 0
        }
        try writePCM(
            to: monoURL,
            channels: 1,
            frameCount: 16_000,
            signal: signal
        )
        try writePCM(
            to: stereoURL,
            channels: 2,
            frameCount: 16_000,
            signal: signal
        )

        let monoAsset = AVAsset(url: monoURL)
        let stereoAsset = AVAsset(url: stereoURL)
        let monoRange = try XCTUnwrap(
            AppleSttPlugin.detectSpeechRange(in: monoAsset)
        )
        let stereoRange = try XCTUnwrap(
            AppleSttPlugin.detectSpeechRange(in: stereoAsset)
        )

        XCTAssertEqual(
            CMTimeGetSeconds(monoRange.start),
            CMTimeGetSeconds(stereoRange.start),
            accuracy: 0.05
        )
        XCTAssertEqual(
            CMTimeGetSeconds(CMTimeRangeGetEnd(monoRange)),
            CMTimeGetSeconds(CMTimeRangeGetEnd(stereoRange)),
            accuracy: 0.05
        )
        XCTAssertLessThanOrEqual(
            CMTimeGetSeconds(CMTimeRangeGetEnd(stereoRange)),
            CMTimeGetSeconds(stereoAsset.duration)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writePCM(
        to url: URL,
        channels: AVAudioChannelCount,
        frameCount: Int,
        signal: (Int) -> Float
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 8_000,
            channels: channels
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var frameOffset = 0
        while frameOffset < frameCount {
            let count = min(1_024, frameCount - frameOffset)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ))
            buffer.frameLength = AVAudioFrameCount(count)
            let channelData = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(channels) {
                for frame in 0..<count {
                    channelData[channel][frame] = signal(frameOffset + frame)
                }
            }
            try file.write(from: buffer)
            frameOffset += count
        }
    }
}
