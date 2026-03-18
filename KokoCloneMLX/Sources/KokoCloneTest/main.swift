import Foundation
import KokoCloneMLX

/// KokoClone MLX Test App
///
/// Usage:
///   kokoclone-test <models-dir> <source-audio.wav> <reference-audio.wav> <output.wav>
///
/// The models directory should contain:
///   - wavlm_base_plus.safetensors
///   - kanade_25hz.safetensors
///   - vocos_mel_24khz.safetensors
///   - mel_filterbank.safetensors
///
/// Source audio: WAV file to convert (e.g., output from Kokoro TTS)
/// Reference audio: WAV file of the target speaker (3-10 seconds of clean speech)
/// Output: Where to save the converted WAV file

func main() throws {
    let args = CommandLine.arguments

    if args.count < 5 {
        print("""
        KokoClone MLX Voice Converter - Test App

        Usage:
          \(args[0]) <models-dir> <source.wav> <reference.wav> <output.wav>

        Arguments:
          models-dir   Directory containing converted safetensors model files
          source.wav   Source speech audio (from Kokoro TTS or any speaker)
          reference.wav Reference audio of target speaker (3-10 seconds)
          output.wav   Path for the voice-converted output

        Steps to prepare:
          1. cd scripts/
          2. pip install -r requirements.txt
          3. python convert_models.py --output-dir ../models
          4. swift run kokoclone-test ../models source.wav reference.wav output.wav

        For a quick test with Kokoro TTS output:
          - Generate speech with Kokoro using any voice
          - Record 5 seconds of the target person speaking
          - Run this tool to convert the Kokoro output to sound like the target

        Validation checks:
          - Output should sound like the reference speaker
          - Content/words should match the source audio
          - Quality should be clear without major artifacts
        """)
        return
    }

    let modelsDir = URL(fileURLWithPath: args[1])
    let sourceURL = URL(fileURLWithPath: args[2])
    let referenceURL = URL(fileURLWithPath: args[3])
    let outputURL = URL(fileURLWithPath: args[4])

    // Verify files exist
    let fm = FileManager.default
    guard fm.fileExists(atPath: modelsDir.path) else {
        print("ERROR: Models directory not found: \(modelsDir.path)")
        return
    }
    guard fm.fileExists(atPath: sourceURL.path) else {
        print("ERROR: Source audio not found: \(sourceURL.path)")
        return
    }
    guard fm.fileExists(atPath: referenceURL.path) else {
        print("ERROR: Reference audio not found: \(referenceURL.path)")
        return
    }

    print("=== KokoClone MLX Voice Converter ===\n")

    // 1. Load models
    print("[1/4] Loading models from \(modelsDir.path)...")
    let converter = VoiceConverter()
    try converter.loadModels(from: modelsDir)
    print("")

    // 2. Load audio files
    print("[2/4] Loading audio files...")
    let (sourceAudio, sourceSR) = try loadWAV(url: sourceURL)
    print("  Source: \(sourceURL.lastPathComponent) (\(sourceSR) Hz, \(String(format: "%.1f", Float(sourceAudio.shape[0]) / Float(sourceSR)))s)")

    let (refAudio, refSR) = try loadWAV(url: referenceURL)
    print("  Reference: \(referenceURL.lastPathComponent) (\(refSR) Hz, \(String(format: "%.1f", Float(refAudio.shape[0]) / Float(refSR)))s)")

    // Resample to 24kHz if needed
    let source24k = (sourceSR != 24000) ? resample(sourceAudio, fromRate: sourceSR, toRate: 24000) : sourceAudio
    let ref24k = (refSR != 24000) ? resample(refAudio, fromRate: refSR, toRate: 24000) : refAudio
    print("")

    // 3. Run voice conversion
    print("[3/4] Converting voice...")
    let converted = try converter.convertVoice(sourceAudio: source24k, referenceAudio: ref24k)
    print("")

    // 4. Save output
    print("[4/4] Saving output...")
    try saveWAV(samples: converted, sampleRate: 24000, to: outputURL)
    let outputSize = try fm.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
    let duration = Float(converted.shape[0]) / 24000.0
    print("  Saved: \(outputURL.path)")
    print("  Duration: \(String(format: "%.1f", duration))s")
    print("  Size: \(outputSize / 1024) KB")

    print("\n=== Done! ===")
    print("Listen to the output and compare with the reference speaker.")
    print("The words should match the source, but the voice should sound like the reference.")

    // Cleanup
    converter.unloadModels()
}

do {
    try main()
} catch {
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}
