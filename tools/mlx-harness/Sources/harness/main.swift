import Foundation
import MLX
import MLXRandom
import MLXUtilsLibrary

// macOS verification harness for the vendored Kokoro/Misaki MLX code.
//
// Subcommands:
//   bart <config.json> <weights.safetensors> <words.txt>
//       Greedy-decode each word through the BART G2P fallback and print
//       "word<TAB>phonemes<TAB>tokenIds". Also prints model-init and
//       per-word timing so cold-start/decode changes are measurable.
//   synth <modelPath.safetensors> <voices.npz> <voiceName> <speed> <textFile> <out.f32>
//       Full Kokoro synthesis; writes raw Float32 samples and prints timing.
//       MLXRandom is seeded before generation so runs are comparable.

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }

let args = CommandLine.arguments
guard args.count >= 2 else {
    die("usage: harness bart|synth ...")
}

switch args[1] {
case "bart":
    guard args.count == 5 else { die("usage: harness bart <config.json> <weights.safetensors> <words.txt>") }
    let configData = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
    let config = try! JSONDecoder().decode(BARTConfig.self, from: configData)

    let t0 = now()
    let weights = try! MLX.loadArrays(url: URL(fileURLWithPath: args[3]))
    let t1 = now()
    let model = BARTModel(config: config, weights: weights)
    // Force lazy weight graphs to materialize so init cost is honest.
    MLX.eval(model.parameters())
    let t2 = now()
    FileHandle.standardError.write(
        "init: load=\(String(format: "%.1f", (t1 - t0) * 1000))ms build=\(String(format: "%.1f", (t2 - t1) * 1000))ms\n"
            .data(using: .utf8)!)

    // Tokenizer replicated from EnglishFallbackNetwork (which is bypassed
    // here only to avoid its Bundle.main resource loading).
    var graphemeToToken: [Character: Int] = [:]
    for (index, grapheme) in config.graphemeChars.enumerated() { graphemeToToken[grapheme] = index }
    var tokenToPhoneme: [Int: Character] = [:]
    for (index, phoneme) in config.phonemeChars.enumerated() { tokenToPhoneme[index] = phoneme }

    let words = try! String(contentsOf: URL(fileURLWithPath: args[4]), encoding: .utf8)
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }

    var totalMs = 0.0
    for word in words {
        var tokens: [Int] = [config.bosTokenId]
        for ch in word { tokens.append(graphemeToToken[ch] ?? 3) }
        tokens.append(config.eosTokenId)
        let inputIds = MLXArray(tokens).reshaped([1, tokens.count])
        let w0 = now()
        let generated = model.generate(inputIds: inputIds)
        let ids = generated.asArray(Int.self)
        let w1 = now()
        totalMs += (w1 - w0) * 1000
        let phonemes = String(ids.compactMap { $0 > 3 ? tokenToPhoneme[$0] : nil })
        print("\(word)\t\(phonemes)\t\(ids.map(String.init).joined(separator: ","))")
    }
    FileHandle.standardError.write(
        "decode: \(words.count) words, total=\(String(format: "%.1f", totalMs))ms, avg=\(String(format: "%.2f", totalMs / Double(max(1, words.count))))ms/word\n"
            .data(using: .utf8)!)

case "synth":
    guard args.count == 8 else {
        die("usage: harness synth <model.safetensors> <voices.npz> <voice> <speed> <textFile> <out.f32>")
    }
    let modelPath = URL(fileURLWithPath: args[2])
    let voicesPath = URL(fileURLWithPath: args[3])
    let voiceName = args[4]
    guard let speed = Float(args[5]) else { die("bad speed") }
    let text = try! String(contentsOf: URL(fileURLWithPath: args[6]), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let outPath = URL(fileURLWithPath: args[7])

    let t0 = now()
    let tts = try! KokoroTTS(modelPath: modelPath, g2p: .misaki)
    let t1 = now()
    guard let voices = NpyzReader.read(fileFromPath: voicesPath),
          let voice = voices[voiceName + ".npy"] else {
        die("voice \(voiceName) not found in \(voicesPath.path)")
    }
    let t2 = now()

    let language: Language = voiceName.hasPrefix("a") ? .enUS : .enGB

    // Seeded so the vocoder's random noise is identical across runs.
    MLXRandom.seed(42)
    let s0 = now()
    let (samples, _) = try! tts.generateAudio(voice: voice, language: language, text: text, speed: speed)
    let s1 = now()

    // Warm second run (model + G2P caches hot), fresh seed for comparability.
    MLXRandom.seed(42)
    let s2 = now()
    let (samples2, _) = try! tts.generateAudio(voice: voice, language: language, text: text, speed: speed)
    let s3 = now()

    var data = Data(capacity: samples.count * 4)
    samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count).withMemoryRebound(to: UInt8.self) { Data(buffer: $0) }) }
    try! data.write(to: outPath)

    var data2 = Data(capacity: samples2.count * 4)
    samples2.withUnsafeBufferPointer { data2.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count).withMemoryRebound(to: UInt8.self) { Data(buffer: $0) }) }
    try! data2.write(to: outPath.appendingPathExtension("warm"))

    print("engineInit=\(String(format: "%.1f", (t1 - t0) * 1000))ms voices=\(String(format: "%.1f", (t2 - t1) * 1000))ms coldSynth=\(String(format: "%.1f", (s1 - s0) * 1000))ms warmSynth=\(String(format: "%.1f", (s3 - s2) * 1000))ms samples=\(samples.count)")

default:
    die("unknown subcommand \(args[1])")
}
