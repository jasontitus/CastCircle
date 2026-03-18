import Foundation
import KokoCloneMLX
import MLX

/// KokoClone MLX Test App — with memory & performance instrumentation.
///
/// Usage:
///   kokoclone-test <models-dir> <source.wav> <reference.wav> <output.wav> [--json metrics.json]

func main() throws {
    let args = CommandLine.arguments

    if args.count < 5 {
        print("""
        KokoClone MLX Voice Converter — Instrumented Test App

        Usage:
          \(args[0]) <models-dir> <source.wav> <reference.wav> <output.wav> [--json metrics.json]

        Arguments:
          models-dir     Directory with converted safetensors model files
          source.wav     Source speech audio (e.g., Kokoro TTS output)
          reference.wav  Reference audio of target speaker (3-10 seconds)
          output.wav     Path for voice-converted output
          --json FILE    Optional: export metrics as JSON for comparison

        Metrics reported:
          • MLX GPU active/peak memory per phase
          • Process RSS (resident set size) per phase
          • Wall-clock time per phase
          • Real-time factor (RTF)
        """)
        return
    }

    let modelsDir = URL(fileURLWithPath: args[1])
    let sourceURL = URL(fileURLWithPath: args[2])
    let referenceURL = URL(fileURLWithPath: args[3])
    let outputURL = URL(fileURLWithPath: args[4])

    // Optional JSON export
    var jsonPath: String? = nil
    if let jsonIdx = args.firstIndex(of: "--json"), jsonIdx + 1 < args.count {
        jsonPath = args[jsonIdx + 1]
    }

    let fm = FileManager.default
    guard fm.fileExists(atPath: modelsDir.path) else {
        print("ERROR: Models directory not found: \(modelsDir.path)"); return
    }
    guard fm.fileExists(atPath: sourceURL.path) else {
        print("ERROR: Source audio not found: \(sourceURL.path)"); return
    }
    guard fm.fileExists(atPath: referenceURL.path) else {
        print("ERROR: Reference audio not found: \(referenceURL.path)"); return
    }

    print("=== KokoClone MLX Voice Converter (Instrumented) ===\n")
    var allMetrics: [PerfMetrics] = []

    // Baseline memory
    let baseline = takeMemorySnapshot()
    print("Baseline — GPU: \(String(format: "%.1f", baseline.gpuActiveMB)) MB, RSS: \(String(format: "%.1f", baseline.processRSSMB)) MB\n")

    // 1. Load models
    print("[1/5] Loading models...")
    let converter = VoiceConverter()
    let (_, loadMetrics) = try instrument("Model loading") {
        try converter.loadModels(from: modelsDir)
    }
    allMetrics.append(loadMetrics)
    print("  ✓ \(String(format: "%.2f", loadMetrics.durationSeconds))s | GPU peak: \(String(format: "%.1f", loadMetrics.gpuPeakMB)) MB | RSS: \(String(format: "%.1f", loadMetrics.memAfter.processRSSMB)) MB\n")

    // 2. Load audio
    print("[2/5] Loading audio...")
    let (sourceAudio, sourceSR) = try loadWAV(url: sourceURL)
    let (refAudio, refSR) = try loadWAV(url: referenceURL)
    let sourceDuration = Float(sourceAudio.shape[0]) / Float(sourceSR)
    let refDuration = Float(refAudio.shape[0]) / Float(refSR)
    print("  Source: \(sourceURL.lastPathComponent) (\(sourceSR) Hz, \(String(format: "%.1f", sourceDuration))s)")
    print("  Reference: \(referenceURL.lastPathComponent) (\(refSR) Hz, \(String(format: "%.1f", refDuration))s)\n")

    let source24k = (sourceSR != 24000) ? resample(sourceAudio, fromRate: sourceSR, toRate: 24000) : sourceAudio
    let ref24k = (refSR != 24000) ? resample(refAudio, fromRate: refSR, toRate: 24000) : refAudio

    // 3. Extract speaker embedding
    print("[3/5] Extracting speaker embedding...")
    let (speakerEmb, embMetrics) = try instrument("Speaker embedding") {
        try converter.extractSpeakerEmbedding(referenceAudio: ref24k)
    }
    allMetrics.append(embMetrics)
    print("  ✓ \(String(format: "%.2f", embMetrics.durationSeconds))s | GPU peak: \(String(format: "%.1f", embMetrics.gpuPeakMB)) MB\n")

    // 4. Voice conversion
    print("[4/5] Converting voice...")
    let (converted, convMetrics) = try instrument("Voice conversion") {
        try converter.convertVoiceWithEmbedding(sourceAudio: source24k, speakerEmbedding: speakerEmb)
    }
    allMetrics.append(convMetrics)
    print("  ✓ \(String(format: "%.2f", convMetrics.durationSeconds))s | GPU peak: \(String(format: "%.1f", convMetrics.gpuPeakMB)) MB\n")

    // 5. Save output
    print("[5/5] Saving output...")
    try saveWAV(samples: converted, sampleRate: 24000, to: outputURL)
    let outputDuration = Double(converted.shape[0]) / 24000.0

    // Calculate total inference time (excluding model load)
    let inferenceMetrics = allMetrics.filter { $0.name != "Model loading" }

    // Print benchmark report
    print("")
    print(formatBenchmarkReport(
        modelName: "KokoClone MLX (WavLM + Kanade-25Hz + Vocos)",
        metrics: allMetrics,
        audioDurationSeconds: Double(sourceDuration)
    ))

    // Model storage sizes
    print("\nModel storage:")
    let modelFiles = ["wavlm_base_plus.safetensors", "kanade_25hz.safetensors",
                      "vocos_mel_24khz.safetensors", "mel_filterbank.safetensors"]
    var totalStorage = 0
    for file in modelFiles {
        let path = modelsDir.appendingPathComponent(file).path
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int {
            print("  \(file): \(size / 1_048_576) MB")
            totalStorage += size
        }
    }
    print("  Total: \(totalStorage / 1_048_576) MB")

    // Export JSON
    if let jsonPath = jsonPath {
        let json = exportMetricsJSON(
            modelName: "kokoclone_mlx",
            metrics: allMetrics,
            audioDurationSeconds: Double(sourceDuration)
        )
        try json.write(toFile: jsonPath, atomically: true, encoding: .utf8)
        print("\nMetrics exported to: \(jsonPath)")
    }

    print("\nOutput: \(outputURL.path) (\(String(format: "%.1f", outputDuration))s)")
    print("Listen and compare with the reference speaker.")

    converter.unloadModels()
}

do {
    try main()
} catch {
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}
