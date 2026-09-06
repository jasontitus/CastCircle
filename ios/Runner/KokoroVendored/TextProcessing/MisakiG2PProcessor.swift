//
//  Kokoro-tts-lib
//

import Foundation
import MLXUtilsLibrary

/// A G2P processor that uses the MisakiSwift library for English phonemization.
final class MisakiG2PProcessor : G2PProcessor {
  /// Lazily initialized once per accent; switching reuses parsed lexicons.
  private var americanEnglish: EnglishG2P?
  private var britishEnglish: EnglishG2P?
  private var misaki: EnglishG2P?

  /// Configures the processor for the specified language.
  func setLanguage(_ language: Language) throws {
    switch language {
    case .enUS:
      if americanEnglish == nil {
        americanEnglish = EnglishG2P(british: false)
      }
      misaki = americanEnglish
    case .enGB:
      if britishEnglish == nil {
        britishEnglish = EnglishG2P(british: true)
      }
      misaki = britishEnglish
    default:
      throw G2PProcessorError.unsupportedLanguage
    }
  }

  /// Converts input text to phonetic representation.
  func process(input: String) throws -> (String, [MToken]?) {
    guard let misaki else { throw G2PProcessorError.processorNotInitialized }
    return misaki.phonemize(text: input)
  }
}
