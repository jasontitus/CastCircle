import Foundation
import MLX
import MLXRandom
import MLXUtilsLibrary

// macOS verification harness for the vendored Kokoro/Misaki MLX code.
//
// Subcommands:
//   bart <config.json> <weights.safetensors> <words.txt>
//       Greedy-decode each word through the BART G2P fallback and print
//       "word<TAB>phonemes<TAB>tokenIds".
//   synth <modelPath.safetensors> <voices.npz> <voiceName> <speed> <textFile> <out.f32>
//       Full Kokoro synthesis; writes raw Float32 samples and prints timing.

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }

func runBart(_ arguments: [String]) throws {
    guard arguments.count == 5 else {
        die("usage: harness bart <config.json> <weights.safetensors> <words.txt>")
    }

    let configData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let config = try JSONDecoder().decode(BARTConfig.self, from: configData)

    let startLoad = now()
    let weights = try MLX.loadArrays(url: URL(fileURLWithPath: arguments[3]))
    let endLoad = now()
    let model = BARTModel(config: config, weights: weights)
    MLX.eval(model.parameters())
    let endBuild = now()
    FileHandle.standardError.write(
        "init: load=\(String(format: "%.1f", (endLoad - startLoad) * 1000))ms build=\(String(format: "%.1f", (endBuild - endLoad) * 1000))ms\n"
            .data(using: .utf8)!
    )

    var graphemeToToken: [Character: Int] = [:]
    for (index, grapheme) in config.graphemeChars.enumerated() {
        graphemeToToken[grapheme] = index
    }
    var tokenToPhoneme: [Int: Character] = [:]
    for (index, phoneme) in config.phonemeChars.enumerated() {
        tokenToPhoneme[index] = phoneme
    }

    let words = try String(
        contentsOf: URL(fileURLWithPath: arguments[4]),
        encoding: .utf8
    )
    .split(whereSeparator: \.isNewline)
    .map(String.init)
    .filter { !$0.isEmpty }

    var totalMilliseconds = 0.0
    for word in words {
        var tokens: [Int] = [config.bosTokenId]
        for character in word {
            tokens.append(graphemeToToken[character] ?? 3)
        }
        tokens.append(config.eosTokenId)
        let inputIds = MLXArray(tokens).reshaped([1, tokens.count])
        let start = now()
        let generated = model.generate(inputIds: inputIds)
        let ids = generated.asArray(Int.self)
        let end = now()
        totalMilliseconds += (end - start) * 1000
        let phonemes = String(ids.compactMap { $0 > 3 ? tokenToPhoneme[$0] : nil })
        print("\(word)\t\(phonemes)\t\(ids.map(String.init).joined(separator: ","))")
    }
    FileHandle.standardError.write(
        "decode: \(words.count) words, total=\(String(format: "%.1f", totalMilliseconds))ms, avg=\(String(format: "%.2f", totalMilliseconds / Double(max(1, words.count))))ms/word\n"
            .data(using: .utf8)!
    )
}

func runSynthesis(_ arguments: [String]) throws {
    guard arguments.count == 8 else {
        die("usage: harness synth <model.safetensors> <voices.npz> <voice> <speed> <textFile> <out.f32>")
    }

    let modelPath = URL(fileURLWithPath: arguments[2])
    let voicesPath = URL(fileURLWithPath: arguments[3])
    let voiceName = arguments[4]
    guard let speed = Float(arguments[5]) else { die("bad speed") }
    let text = try String(
        contentsOf: URL(fileURLWithPath: arguments[6]),
        encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let outputPath = URL(fileURLWithPath: arguments[7])

    let startInitialization = now()
    let tts = try KokoroTTS(modelPath: modelPath, g2p: .misaki)
    let endInitialization = now()
    guard let voices = NpyzReader.read(fileFromPath: voicesPath),
          let voice = voices[voiceName + ".npy"] else {
        die("voice \(voiceName) not found in \(voicesPath.path)")
    }
    let endVoiceLoad = now()
    let language: Language = voiceName.hasPrefix("a") ? .enUS : .enGB

    MLXRandom.seed(42)
    let startColdSynthesis = now()
    let (samples, _) = try tts.generateAudio(
        voice: voice,
        language: language,
        text: text,
        speed: speed
    )
    let endColdSynthesis = now()

    MLXRandom.seed(42)
    let startWarmSynthesis = now()
    let (warmSamples, _) = try tts.generateAudio(
        voice: voice,
        language: language,
        text: text,
        speed: speed
    )
    let endWarmSynthesis = now()

    var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
    samples.withUnsafeBufferPointer {
        data.append(
            UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)
                .withMemoryRebound(to: UInt8.self) { Data(buffer: $0) }
        )
    }
    try data.write(to: outputPath)

    var warmData = Data(capacity: warmSamples.count * MemoryLayout<Float>.size)
    warmSamples.withUnsafeBufferPointer {
        warmData.append(
            UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)
                .withMemoryRebound(to: UInt8.self) { Data(buffer: $0) }
        )
    }
    try warmData.write(to: outputPath.appendingPathExtension("warm"))

    print(
        "engineInit=\(String(format: "%.1f", (endInitialization - startInitialization) * 1000))ms " +
        "voices=\(String(format: "%.1f", (endVoiceLoad - endInitialization) * 1000))ms " +
        "coldSynth=\(String(format: "%.1f", (endColdSynthesis - startColdSynthesis) * 1000))ms " +
        "warmSynth=\(String(format: "%.1f", (endWarmSynthesis - startWarmSynthesis) * 1000))ms " +
        "samples=\(samples.count)"
    )
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    die("usage: harness bart|synth ...")
}

do {
    switch arguments[1] {
    case "bart":
        try runBart(arguments)
    case "synth":
        try runSynthesis(arguments)
    default:
        die("unknown subcommand \(arguments[1])")
    }
} catch {
    die("error: \(error.localizedDescription)")
}
