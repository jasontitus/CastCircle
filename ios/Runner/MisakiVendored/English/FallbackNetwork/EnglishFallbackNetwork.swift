import Foundation
import MLX
import MLXUtilsLibrary

final class EnglishFallbackNetwork {
  static let unknownTokenId = 3
  
  private let configuration: BARTConfig
  private let modelWeights: [String: MLXArray]
  private let model: BARTModel
  private let graphemeToToken: [Character: Int]
  private let tokenToPhoneme: [Int: Character]

  private let british: Bool
  private let resultCache = NSCache<NSString, NSString>()
    
  /// Failable: missing/corrupt bundled BART config or weights used to
  /// force-unwrap and crash the app at G2P init. Callers fall back to
  /// lexicon-only phonemization instead.
  init?(british: Bool) {
    guard let config = EnglishFallbackNetwork.loadConfig(british: british),
          let weights = EnglishFallbackNetwork.loadWeights(british: british) else {
      NSLog("EnglishFallbackNetwork: BART config/weights missing — lexicon-only G2P")
      return nil
    }
    configuration = config
    modelWeights = weights
    
    self.british = british
    
    self.model = BARTModel(config: configuration, weights: modelWeights)
    
    var graphemeDict: [Character: Int] = [:]
    for (index, grapheme) in configuration.graphemeChars.enumerated() {
      graphemeDict[grapheme] = index
    }
    self.graphemeToToken = graphemeDict

    var phonemeDict: [Int: Character] = [:]
    for (index, phoneme) in configuration.phonemeChars.enumerated() {
       phonemeDict[index] = phoneme
    }
    self.tokenToPhoneme = phonemeDict    
    resultCache.countLimit = 256
  }
  
  private func graphemesToTokens(_ graphemes: String) -> [Int]? {
    guard configuration.maxPositionEmbeddings >= 2 else { return nil }

    var tokens: [Int] = [configuration.bosTokenId]
    tokens.reserveCapacity(configuration.maxPositionEmbeddings)

    for char in graphemes {
      // Reserve the final position for EOS. BART's position table cannot
      // encode more than maxPositionEmbeddings input tokens.
      guard tokens.count < configuration.maxPositionEmbeddings - 1 else {
        return nil
      }

      if let tokenId = graphemeToToken[char] {
        tokens.append(tokenId)
      } else {
        tokens.append(EnglishFallbackNetwork.unknownTokenId)
      }
    }

    tokens.append(configuration.eosTokenId)
    return tokens
  }
      
  private func tokensToPhonemes(_ tokens: [Int]) -> String {
    var phonemes = ""
    
    for token in tokens {
      if token > EnglishFallbackNetwork.unknownTokenId {
        if let phoneme = tokenToPhoneme[Int(token)] {
          phonemes += String(phoneme)
        }
      }
    }
    
    return phonemes
  }
  
  func callAsFunction(_ word: MToken) -> (phoneme: String, rating: Int)? {
    let normalizedWord = word.text.precomposedStringWithCanonicalMapping
    let cacheKey = "\(british ? "en-GB" : "en-US")\u{0}\(normalizedWord)" as NSString
    if let cached = resultCache.object(forKey: cacheKey) {
      return (cached as String, 1)
    }

    guard let tokenIds = graphemesToTokens(normalizedWord) else { return nil }

    let inputIds = MLXArray(tokenIds).reshaped([1, tokenIds.count])
    let generatedIds = model.generate(inputIds: inputIds)
    let outputText = tokensToPhonemes(generatedIds.asArray(Int.self))
    resultCache.setObject(outputText as NSString, forKey: cacheKey)

    return (outputText, 1)
  }
  
  private static func loadConfig(british: Bool) -> BARTConfig? {
    let fileName = "\(british ? "gb" : "us")_bart_config"
    
    
    guard let url = Bundle.main.url(forResource: fileName, withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let config = try? JSONDecoder().decode(BARTConfig.self, from: data) else {
        return nil
    }
    return config
  }
  
  private static func loadWeights(british: Bool) -> [String: MLXArray]? {
    let fileName = "\(british ? "gb" : "us")_bart"
    guard let url = Bundle.main.url(forResource: fileName, withExtension: "safetensors"),
          let weights = try? MLX.loadArrays(url: url) else {
      return nil
    }
    return weights
  }
}
