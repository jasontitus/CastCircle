import Foundation
import NaturalLanguage
import MLXUtilsLibrary

// Main G2P pipeline for English text
final public class EnglishG2P {
  private let british: Bool
  private let tagger: NLTagger
  private let lexicon: Lexicon
  private let fallback: EnglishFallbackNetwork?
  private let unk: String
    
  static let punctuationTags: Set<NLTag> =  Set([.openQuote, .closeQuote, .openParenthesis, .closeParenthesis, .punctuation, .sentenceTerminator, .otherPunctuation])
  static let punctuactions: Set<Character> = Set(";:,.!?—…\"“”")
  
  // spaCy-style punctuation tags https://github.com/explosion/spaCy/blob/master/spacy/glossary.py
  static let punctuationTagPhonemes: [String: String] = [
      "``": String(UnicodeScalar(8220)!),     // Left double quotation mark
      "\"\"": String(UnicodeScalar(8221)!),   // Right double quotation mark
      "''": String(UnicodeScalar(8221)!)      // Right double quotation mark
  ]
  
  static let nonQuotePunctuations: Set<Character> = Set(punctuactions.filter { !"\"“”".contains($0) })
  static let vowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
  static let consonants: Set<Character> = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
  static let subTokenJunks: Set<Character> = Set("',-._''/")
  // Splits words into subtokens such as acronym boundaries, signs, commas, decimals, multiple quotes, camelCase boundaries and so forth.
  static let subtokenizeRegexPattern = #"^[''']+|\p{Lu}(?=\p{Lu}\p{Ll})|(?:^-)?(?:\d?[,.]?\d)+|[-_]+|[''']{2,}|\p{L}*?(?:[''']\p{L})*?\p{Ll}(?=\p{Lu})|\p{L}+(?:[''']\p{L})*|[^-_\p{L}'''\d]|[''']+$"#
  static let subtokenizeRegex = try! NSRegularExpression(pattern: EnglishG2P.subtokenizeRegexPattern, options: [])
  static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]*)\)"#, options: [])
  
  struct PreprocessFeature {
    enum Value {
      case int(Int)
      case double(Double)
      case string(String)
    }
    
    let value: Value
    let tokenRange: Range<String.Index>
  }
  private struct LexiconCandidate {
    let left: Int
    let text: String
    let tag: NLTag?
    let featureStress: Double?
    let currency: String?
    let isHead: Bool
    let numFlags: String
  }

  // Candidate probing is bounded so an adversarially fragmented token cannot
  // make lexicon fallback quadratic in its subtoken count.
  private static let maxCompoundSubtokens = 16

  private static func casingScore(_ token: MToken) -> Int {
    token.text.reduce(0) {
      $0 + (String($1) == String($1).lowercased() ? 1 : 2)
    }
  }

  public init(british: Bool = false, unk: String = "❓") {
    self.british = british
    self.tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
    self.lexicon = Lexicon(british: british)
    self.fallback = EnglishFallbackNetwork(british: british)
    self.unk = unk
  }

  private func tokenContext(_ ctx: TokenContext, ps: String?, token: MToken) -> TokenContext {
    var vowel = ctx.futureVowel
    
    if let ps = ps {
      for c in ps {
        if EnglishG2P.nonQuotePunctuations.contains(c) {
          vowel = nil
          break
        }
        
        if EnglishG2P.vowels.contains(c) {
          vowel = true
          break
        }
        
        if EnglishG2P.consonants.contains(c) {
          vowel = false
          break
        }
      }
    }
    let futureTo = (token.text == "to" || token.text == "To") || (token.text == "TO" && (token.tag == .particle || token.tag == .preposition))
    return TokenContext(futureVowel: vowel, futureTo: futureTo)
  }
  
  func stressWeight(_ phonemes: String?) -> Int {
    let dipthongs = Set("AIOQWYʤʧ")
    guard let phonemes else { return 0 }
    return phonemes.reduce(0) { sum, character in
      sum + (dipthongs.contains(character) ? 2 : 1)
    }
  }
  
  private func resolveTokens(_ tokens: inout [MToken]) {
    let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + (tokens.last?.text ?? "")
    let prespace = text.contains(" ") || text.contains("/") || Set(text.compactMap { c -> Int? in
      if EnglishG2P.subTokenJunks.contains(c) { return nil }
      
      if c.isLetter { return 0 }
      if c.isNumber { return 1 }
      return 2
    }).count > 1
        
    for i in 0..<tokens.count {
      if tokens[i].phonemes == nil {
        if i == tokens.count - 1, let last = tokens[i].text.last, EnglishG2P.nonQuotePunctuations.contains(last) {
          tokens[i].phonemes = tokens[i].text
          tokens[i].`_`.rating = 3
        } else if tokens[i].text.allSatisfy({ EnglishG2P.subTokenJunks.contains($0) }) {
          tokens[i].phonemes = nil
          tokens[i].`_`.rating = 3
        }
      } else if i > 0 {
          tokens[i].`_`.prespace = prespace
      }
    }
    
    guard !prespace else { return }
    
    var indices: [(Bool, Int, Int)] = []
    for (i, tk) in tokens.enumerated() {
      if let ps = tk.phonemes, !ps.isEmpty {
        indices.append((ps.contains(Lexicon.primaryStress), stressWeight(ps), i))
      }
    }
    if indices.count == 2, tokens[indices[0].2].text.count == 1 {
        let i = indices[1].2
      tokens[i].phonemes = Lexicon.applyStress(tokens[i].phonemes, stress: -0.5)
        return
    } else if indices.count < 2 || indices.map({ $0.0 ? 1 : 0 }).reduce(0, +) <= (indices.count + 1) / 2 {
        return
    }
    indices.sort { ($0.0 ? 1 : 0, $0.1) < ($1.0 ? 1 : 0, $1.1) }
    let cut = indices.prefix(indices.count / 2)

    for x in cut {
      let i = x.2
      tokens[i].phonemes = Lexicon.applyStress(tokens[i].phonemes, stress: -0.5)
    }
  }
    
  // Text pre-processing tuple for easing the tokenization
  typealias PreprocessTuple = (text: String, tokens: [String], features: [PreprocessFeature])
    
  /// Preprocesses the string in case there are some parts where the pronounciation or stress is pre-dictated using Markdown-like link format, e.g.
  /// "[Misaki](/misˈɑki/) is a G2P engine designed for [Kokoro](/kˈOkəɹO/) models."
  private func preprocess(text: String) -> PreprocessTuple {
    var result = ""
    var tokens: [String] = []
    var features: [PreprocessFeature] = []

    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var lastEnd = input.startIndex
    let ns = input as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
 
    EnglishG2P.linkRegex.enumerateMatches(in: input, options: [], range: fullRange) { match, _, _ in
      guard let match,
            let range = Range(match.range, in: input),
            let graphemeRange = Range(match.range(at: 1), in: input),
            let phonemeRange = Range(match.range(at: 2), in: input) else {
        return
      }

      result += String(input[lastEnd..<range.lowerBound])
      tokens.append(contentsOf: String(input[lastEnd..<range.lowerBound]).split(separator: " ").map(String.init))

      let grapheme = String(input[graphemeRange])
      let phoneme = String(input[phonemeRange])
      
      let tokenStartIndex = result.endIndex
      result += grapheme
      let tokenRange = tokenStartIndex..<result.endIndex

      if let intValue = Int(phoneme) {
        features.append(PreprocessFeature(value: .int(intValue), tokenRange: tokenRange))
      } else if ["0.5", "+0.5"].contains(phoneme) {
        features.append(PreprocessFeature(value: .double(0.5), tokenRange: tokenRange))
      } else if phoneme == "-0.5" {
        features.append(PreprocessFeature(value: .double(-0.5), tokenRange: tokenRange))
      } else if phoneme.count > 1 && phoneme.first == "/" && phoneme.last == "/" {
        features.append(PreprocessFeature(value: .string(String(phoneme.dropLast())), tokenRange: tokenRange))
      } else if phoneme.count > 1 && phoneme.first == "#" && phoneme.last == "#" {
        features.append(PreprocessFeature(value: .string(String(phoneme.dropLast())), tokenRange: tokenRange))
      }

      tokens.append(grapheme)
      lastEnd = range.upperBound
    }
    
    if lastEnd < input.endIndex {
      result += String(input[lastEnd...])
      tokens.append(contentsOf: String(input[lastEnd...]).split(separator: " ").map(String.init))
    }
    
    return (text: result, tokens: tokens, features: features)
  }
    
  private func tokenize(preprocessedText: PreprocessTuple) -> [MToken] {
    var mutableTokens: [MToken] = []

    // Guard against empty or whitespace-only text that crashes NLTagger/ICU
    let text = preprocessedText.text
    guard !text.isEmpty, text.rangeOfCharacter(from: .alphanumerics) != nil else {
      return mutableTokens
    }

    // Tokenize and perform part-of-speech tagging
    tagger.string = text
    tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
    let options: NLTagger.Options = []
    tagger.enumerateTags(
      in: text.startIndex..<text.endIndex,
      unit: .word,
      scheme: .nameTypeOrLexicalClass,
      options: options) { tag, tokenRange in
      if let tag = tag {
        let word = String(text[tokenRange])
        if tag == .whitespace, let lastToken = mutableTokens.last {
          lastToken.whitespace = word
        } else {
          mutableTokens.append(MToken(text: word, tokenRange: tokenRange, tag: tag, whitespace: ""))
        }
      }
        
      return true
    }
                            
    // Features and tokens are both emitted in source order. Advance through
    // them together rather than rescanning every token for every feature.
    var tokenIndex = 0
    for feature in preprocessedText.features {
      while tokenIndex < mutableTokens.count,
            mutableTokens[tokenIndex].tokenRange.upperBound <= feature.tokenRange.lowerBound {
        tokenIndex += 1
      }

      var overlappingTokenIndex = tokenIndex
      while overlappingTokenIndex < mutableTokens.count,
            mutableTokens[overlappingTokenIndex].tokenRange.lowerBound < feature.tokenRange.upperBound {
        let token = mutableTokens[overlappingTokenIndex]
        if token.tokenRange.contains(feature.tokenRange) || feature.tokenRange.contains(token.tokenRange) {
          switch feature.value {
            case .int(let int):
              token.`_`.stress = Double(int)
            case .double(let double):
              token.`_`.stress = double
            case .string(let string):
              if string.hasPrefix("/") {
                token.`_`.is_head = true
                token.phonemes = String(string.dropFirst())
                token.`_`.rating = 5
              } else if string.hasPrefix("#") {
                token.`_`.num_flags = String(string.dropFirst())
              }
          }
        }
        overlappingTokenIndex += 1
      }
    }

    return mutableTokens
  }
  
  func mergeTokens<T: RandomAccessCollection>(_ tokens: T, unk: String? = nil) -> MToken where T.Element == MToken {
    let stressSet = Set(tokens.compactMap { $0._.stress })
    let currencySet = Set(tokens.compactMap { $0._.currency })
    let ratings: Set<Int?> = Set(tokens.map { $0._.rating })
        
    var phonemes: String? = nil
    if let unk {
      var phonemeBuilder = ""
      for token in tokens {
        if token._.prespace,
           !phonemeBuilder.isEmpty,
           !(phonemeBuilder.last?.isWhitespace ?? false),
           token.phonemes != nil {
          phonemeBuilder += " "
        }
        phonemeBuilder += token.phonemes ?? unk
      }
      phonemes = phonemeBuilder
    }
    
    // Concatenate surface text and whitespace
    let mergedText = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + (tokens.last?.text ?? "")

    // Choose tag from token with highest casing score
    let tagSource = tokens.max {
      EnglishG2P.casingScore($0) < EnglishG2P.casingScore($1)
    }
    
    let tokenRangeStart = tokens.first!.tokenRange.lowerBound
    let tokenRangeEnd = tokens.last!.tokenRange.upperBound
    let flagChars = Set(tokens.flatMap { Array($0._.num_flags) })
    
    return MToken(
      text: mergedText,
      tokenRange: Range<String.Index>(uncheckedBounds: (lower: tokenRangeStart, upper: tokenRangeEnd)),
      tag: tagSource?.tag,
      whitespace: tokens.last?.whitespace ?? "",
      phonemes: phonemes,
      start_ts: tokens.first?.start_ts,
      end_ts: tokens.last?.end_ts,
      underscore: Underscore(
        is_head: tokens.first?._.is_head ?? false,
        alias: nil,
        stress: (stressSet.count == 1 ? stressSet.first : nil),
        currency: currencySet.max(),
        num_flags: String(flagChars.sorted()),
        prespace: tokens.first?._.prespace ?? false,
        rating: ratings.contains(where: { $0 == nil }) ? nil : ratings.compactMap { $0 }.min()
      )
    )
  }
    
  func foldLeft(_ tokens: [MToken]) -> [MToken] {
    var result: [MToken] = []
    for token in tokens {
      if let last = result.last, !token.`_`.is_head {
        _ = result.popLast()
        let merged = mergeTokens([last, token], unk: unk)
        result.append(merged)
      } else {
        result.append(token)
      }
    }
    return result
  }
  
  func subtokenize(word: String) -> [String] {
    let nsString = word as NSString
    let range = NSRange(location: 0, length: nsString.length)
    let matches = EnglishG2P.subtokenizeRegex.matches(in: word, options: [], range: range)
    
    return matches.map { match in
      nsString.substring(with: match.range)
    }
  }
  
  func retokenize(_ tokens: [MToken]) -> [Any] {
    var words: [Any] = []
    var currency: String? = nil
    
    for (i, token) in tokens.enumerated() {
      let needsSplit = (token.`_`.alias == nil && token.phonemes == nil)
      var subtokens: [MToken] = []
      if needsSplit {
        let parts = subtokenize(word: token.text)
        subtokens = parts.map { part in
          let t = MToken(copying: token)
          t.text = part
          t.whitespace = ""
          t.`_`.is_head = true
          t.`_`.prespace = false
          return t
        }
      } else {
        subtokens = [token]
      }
      subtokens.last?.whitespace = token.whitespace
          
      for j in 0..<subtokens.count {
        let token = subtokens[j]
      
        if token.`_`.alias != nil || token.phonemes != nil {
          // Do nothing at his point
        } else if token.tag == .otherWord, Lexicon.currencies[token.text] != nil {
          currency = token.text
          token.phonemes = ""
          token.`_`.rating = 4
        } else if token.tag == .dash || (token.tag == .punctuation && token.text == "–") {
          token.phonemes = "—"
          token.`_`.rating = 3
        } else if let tag = token.tag, EnglishG2P.punctuationTags.contains(tag), !token.text.lowercased().unicodeScalars.allSatisfy({ (97...122).contains(Int($0.value)) }) {
          if let val = EnglishG2P.punctuationTagPhonemes[token.text] {
            token.phonemes = val
          } else {
            token.phonemes = token.text.filter { EnglishG2P.punctuactions.contains($0) }
          }
          token.`_`.rating = 4
        } else if currency != nil {
          if token.tag != .number {
            currency = nil
          } else if j + 1 == subtokens.count && (i + 1 == tokens.count || tokens[i + 1].tag != .number) {
            token.`_`.currency = currency
          }
        } else if j > 0 && j < subtokens.count - 1 && token.text == "2" {
          let prev = subtokens[j - 1].text
          let next = subtokens[j + 1].text
          // Parenthesised deliberately: `a ?? "" + b` parses as `a ?? ("" + b)`,
          // which never looked at `next` when `prev.last` existed.
          if ((prev.last.map { String($0) } ?? "") + (next.first.map { String($0) } ?? "")).allSatisfy({ $0.isLetter }) ||
             (prev == "-" && next == "-") {
            token.`_`.alias = "to"
          }
        }
           
        if token.`_`.alias != nil || token.phonemes != nil {
          words.append(token)
        } else if let last = words.last as? [MToken], last.last?.whitespace.isEmpty == true {
          var arr = last
          token.`_`.is_head = false
          arr.append(token)
          _ = words.popLast()
          words.append(arr)
        } else {
          if token.whitespace.isEmpty { words.append([token]) } else { words.append(token) }
        }
      }
    }
                
    return words.map { item in
      if let arr = item as? [MToken], arr.count == 1 { return arr[0] }
      return item
    }
  }
   
  // Turns the text into phonemes that can then be fed to text-to-speech (TTS) engine for converting to audio
  public func phonemize(text: String, performPreprocess: Bool = true) -> (String, [MToken]) {
    let pre: PreprocessTuple
    if performPreprocess {
        pre = self.preprocess(text: text)
    } else {
        pre = (text: text, tokens: [], features: [])
    }

    var tokens = tokenize(preprocessedText: pre)
    tokens = foldLeft(tokens)
    
    let words = retokenize(tokens)
    
    var ctx = TokenContext()
    for i in stride(from: words.count - 1, through: 0, by: -1) {
      if let w = words[i] as? MToken {
        if w.phonemes == nil {
          let out = lexicon.transcribe(w, ctx: ctx)
          w.phonemes = out.0
          w.`_`.rating = out.1
        }
        
        if w.phonemes == nil {
          // No BART fallback (failed to load): mark unknown, keep going.
          if let out = fallback?(w) {
            w.phonemes = out.0
            w.`_`.rating = out.1
          } else {
            w.phonemes = unk
            w.`_`.rating = 1
          }
        }
        
        ctx = tokenContext(ctx, ps: w.phonemes, token: w)
      } else if var arr = words[i] as? [MToken] {
        var right = arr.count
        var shouldFallback = false

        // Record the nearest fixed token at or before every boundary. A
        // candidate cannot cross aliases or already-resolved phonemes.
        var lastFixedBefore = [Int](repeating: -1, count: arr.count + 1)
        for index in arr.indices {
          let isFixed = arr[index].`_`.alias != nil || arr[index].phonemes != nil
          lastFixedBefore[index + 1] = isFixed ? index : lastFixedBefore[index]
        }

        while right > 0 {
          let minimumLeft = lastFixedBefore[right] + 1
          if minimumLeft == right {
            right -= 1
            continue
          }

          let boundedLeft = max(minimumLeft, right - EnglishG2P.maxCompoundSubtokens)
          var candidates: [LexiconCandidate] = []
          candidates.reserveCapacity(right - boundedLeft)

          var candidateText = ""
          var tagSource: MToken?
          var tagScore = Int.min
          var stressValues = Set<Double>()
          var currencies = Set<String>()
          var flagCharacters = Set<Character>()

          // Build each suffix incrementally from shortest to longest. Probe in
          // reverse below to preserve the existing longest-match preference.
          for candidateLeft in stride(from: right - 1, through: boundedLeft, by: -1) {
            let component = arr[candidateLeft]
            if candidateLeft == right - 1 {
              candidateText = component.text
            } else {
              candidateText = component.text + component.whitespace + candidateText
            }

            let componentScore = EnglishG2P.casingScore(component)
            if componentScore >= tagScore {
              tagSource = component
              tagScore = componentScore
            }
            if let stress = component.`_`.stress {
              stressValues.insert(stress)
            }
            if let currency = component.`_`.currency {
              currencies.insert(currency)
            }
            flagCharacters.formUnion(component.`_`.num_flags)

            candidates.append(LexiconCandidate(
              left: candidateLeft,
              text: candidateText,
              tag: tagSource?.tag,
              featureStress: stressValues.count == 1 ? stressValues.first : nil,
              currency: currencies.max(),
              isHead: component.`_`.is_head,
              numFlags: String(flagCharacters.sorted())))
          }

          var matchedCandidate: LexiconCandidate?
          var matchedPhonemes: String?
          var matchedRating: Int?
          for candidate in candidates.reversed() {
            let result = lexicon.transcribe(
              candidate.text,
              tag: candidate.tag,
              featureStress: candidate.featureStress,
              currency: candidate.currency,
              isHead: candidate.isHead,
              numFlags: candidate.numFlags,
              ctx: ctx)
            if let phonemes = result.0 {
              matchedCandidate = candidate
              matchedPhonemes = phonemes
              matchedRating = result.1
              break
            }
          }

          if let candidate = matchedCandidate, let phonemes = matchedPhonemes {
            let token = mergeTokens(arr[candidate.left..<right])
            arr[candidate.left].phonemes = phonemes
            arr[candidate.left].`_`.rating = matchedRating
            for index in (candidate.left + 1)..<right {
              arr[index].phonemes = ""
              arr[index].`_`.rating = matchedRating
            }
            ctx = tokenContext(ctx, ps: phonemes, token: token)
            right = candidate.left
            continue
          }

          right -= 1
          let last = arr[right]
          if last.phonemes == nil {
            if last.text.allSatisfy({ EnglishG2P.subTokenJunks.contains($0) }) {
              last.phonemes = ""
              last.`_`.rating = 3
            } else {
              shouldFallback = true
              break
            }
          }
          arr[right] = last
        }
        
        if shouldFallback {
          let token = mergeTokens(arr)
          let first = arr[0]
          let out: (String?, Int?) = fallback?(token) ?? (unk, 1)
          first.phonemes = out.0
          first.`_`.rating = out.1
          arr[0] = first
          if arr.count > 1 {
            for j in 1..<arr.count {
              arr[j].phonemes = ""
              arr[j].`_`.rating = out.1
            }
          }
        } else {
          resolveTokens(&arr)
        }
      }
    }
    
    let finalTokens: [MToken] = words.map { item in
      if let arr = item as? [MToken] { return mergeTokens(arr, unk: self.unk) }
      return item as! MToken
    }
        
    for i in 0..<finalTokens.count {
      if var ps = finalTokens[i].phonemes, !ps.isEmpty {
        ps = ps.replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t")
        finalTokens[i].phonemes = ps
      }
    }

    let result = finalTokens.map { ( $0.phonemes ?? self.unk ) + $0.whitespace }.joined()
    return (result, finalTokens)
  }
}
