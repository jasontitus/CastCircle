//
//  Kokoro-tts-lib
//

import Foundation
import MLXUtilsLibrary

/// A G2P processor that uses the MisakiSwift library for English phonemization.
final class MisakiG2PProcessor : G2PProcessor {
  /// The underlying MisakiSwift English G2P engine instance.
  var misaki: EnglishG2P?

  /// Configures the processor for the specified language.
  func setLanguage(_ language: Language) throws {
    switch language {
    case .enUS:
      misaki = EnglishG2P(british: false)
    case .enGB:
      misaki = EnglishG2P(british: true)
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
