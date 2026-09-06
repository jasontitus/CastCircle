import Foundation

/// Converts numbers to English words, converted from num2words Python package and from Num2Word_EN class
struct EnglishNum2Word {
  enum ConversionFormat {
    case ordinal
    case ordinalNum
    case decimal
    case year
  }
  
  private let negWord = "minus "
  private let pointWord = "point"
  private let excludeTitle = ["and", "point", "minus"]
  
  private let midNumWords: [(Int, String)] = [
    (1000, "thousand"), (100, "hundred"),
    (90, "ninety"), (80, "eighty"), (70, "seventy"),
    (60, "sixty"), (50, "fifty"), (40, "forty"),
    (30, "thirty"), (20, "twenty")
  ]
  
  private let lowNumWords = [
    "twenty", "nineteen", "eighteen", "seventeen",
    "sixteen", "fifteen", "fourteen", "thirteen",
    "twelve", "eleven", "ten", "nine", "eight",
    "seven", "six", "five", "four", "three", "two",
    "one", "zero"
  ]
  
  private let ords: [String: String] = [
    "one": "first", "two": "second", "three": "third",
    "four": "fourth", "five": "fifth", "six": "sixth",
    "seven": "seventh", "eight": "eighth", "nine": "ninth",
    "ten": "tenth", "eleven": "eleventh", "twelve": "twelfth"
  ]
  
  // Cards sorted largest-first, computed once (toCardinal recurses; sorting
  // inside it would re-sort the table on every recursion level).
  private let cardsDescending: [(UInt, String)]

  init() {
    // Initialize high number words
    var cards: [UInt: String] = [:]
    let highWords = ["m", "b", "tr", "quadr", "quint", "sext", "sept", "oct", "non", "dec"]
    for (index, word) in highWords.enumerated() {
      let power = 6 + (index * 3)
      let val = pow(10.0, Double(power))
      if val <= Double(UInt.max) {
        let intVal = UInt(val)
        cards[intVal] = word + "illion"
      } else {
        // Currently really, really large numbers are not handled
      }      
    }
    self.cardsDescending = cards.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
  }
  
  private func merge(_ lPair: (String, Int), _ rPair: (String, Int)) -> (String, Int) {
    let (lText, lNum) = lPair
    let (rText, rNum) = rPair
    
    if lNum == 1 && rNum < 100 {
      return (rText, rNum)
    } else if 100 > lNum && lNum > rNum {
      return ("\(lText)-\(rText)", lNum + rNum)
    } else if lNum >= 100 && rNum < 100 {
      return ("\(lText) and \(rText)", lNum + rNum)
    } else if rNum > lNum {
      return ("\(lText) \(rText)", lNum * rNum)
    }
    return ("\(lText), \(rText)", lNum + rNum)
  }
  
  private func toOrdinal(_ decimalNumber: Decimal) -> String {
    let number = NSDecimalNumber(decimal: decimalNumber).intValue
    guard number > 0 else { return "" }
    
    var outWords = toCardinal(number).components(separatedBy: " ")
    var lastWords = outWords[outWords.count - 1].components(separatedBy: "-")
    var lastWord = lastWords[lastWords.count - 1].lowercased()
    
    if let ordinalWord = ords[lastWord] {
      lastWord = ordinalWord
    } else {
      if lastWord.hasSuffix("y") {
        lastWord = String(lastWord.dropLast()) + "ie"
      }
      lastWord += "th"
    }
    
    lastWords[lastWords.count - 1] = lastWord.capitalized
    outWords[outWords.count - 1] = lastWords.joined(separator: "-")
    return outWords.joined(separator: " ")
  }
  
  private func toOrdinalNum(_ decimalNumber: Decimal) -> String {
    let number = NSDecimalNumber(decimal: decimalNumber).intValue
    let ordinal = toOrdinal(decimalNumber)
    if ordinal.count >= 2 {
      let suffix = String(ordinal.suffix(2))
      return "\(number)\(suffix)"
    } else {
      return ""
    }
  }
  
  private func toCardinal(_ number: Int) -> String {
    if number < 0 {
      return negWord + toCardinal(number.magnitude)
    }
    return toCardinal(UInt(number))
  }

  private func toCardinal(_ number: UInt) -> String {
    if number < 21 {
      return lowNumWords[20 - Int(number)]
    }
    
    // Handle numbers from 21-99
    if number < 100 {
      let tens = (number / 10) * 10
      let ones = number % 10
      if ones == 0 {
        return midNumWords.first { UInt($0.0) == tens }?.1 ?? ""
      } else {
        let tensWord = midNumWords.first { UInt($0.0) == tens }?.1 ?? ""
        let onesWord = lowNumWords[20 - Int(ones)]
        return "\(tensWord)-\(onesWord)"
      }
    }
    
    // Handle hundreds
    if number < 1000 {
      let hundreds = number / 100
      let remainder = number % 100
      let hundredsWord = toCardinal(hundreds) + " hundred"
      if remainder == 0 {
        return hundredsWord
      } else {
        return "\(hundredsWord) and \(toCardinal(remainder))"
      }
    }

    // High cards must precede thousand: every million-scale value also
    // satisfies the thousand branch.
    for (value, word) in cardsDescending {
      if number >= value {
        let quotient = number / value
        let remainder = number % value
        let quotientWord = toCardinal(quotient)
        if remainder == 0 {
          return "\(quotientWord) \(word)"
        } else {
          return "\(quotientWord) \(word), \(toCardinal(remainder))"
        }
      }
    }
    
    // Handle thousands after the larger cards.
    for (value, word) in midNumWords {
      let unsignedValue = UInt(value)
      if number >= unsignedValue {
        let quotient = number / unsignedValue
        let remainder = number % unsignedValue
        let quotientWord = toCardinal(quotient)
        if remainder == 0 {
          return "\(quotientWord) \(word)"
        } else {
          return "\(quotientWord) \(word), \(toCardinal(remainder))"
        }
      }
    }

    return ""
  }
  
  private func toYear(_ yearDecimal: Decimal, suffix: String? = nil, longVal: Bool = true) -> String {
    let year = NSDecimalNumber(decimal: yearDecimal).intValue
    let val = year.magnitude
    var finalSuffix = suffix
    
    if year < 0 {
      finalSuffix = finalSuffix ?? "BC"
    }
    
    let high = val / 100
    let low = val % 100
    
    let valText: String
    // If year is 00XX, X00X, or beyond 9999, go cardinal
    if high == 0 || (high % 10 == 0 && low < 10) || high >= 100 {
      valText = toCardinal(val)
    } else {
      let highText = toCardinal(high)
      let lowText: String
      if low == 0 {
        lowText = "hundred"
      } else if low < 10 {
        lowText = "oh-\(toCardinal(low))"
      } else {
        lowText = toCardinal(low)
      }
      valText = "\(highText) \(lowText)"
    }
    
    if let suffix = finalSuffix {
      return "\(valText) \(suffix)"
    } else {
      return valText
    }
  }
  
  private func toDecimal(_ number: Decimal) -> String {
    let integerPart = NSDecimalNumber(decimal: number).intValue
    let fractionalPart = number - Decimal(integerPart)
    
    if fractionalPart == 0 {
      return toCardinal(integerPart)
    }
    
    var integerWords = toCardinal(integerPart)
    if integerPart == 0, number < 0 {
      integerWords = negWord + integerWords
    }

    let fractionalMagnitude = fractionalPart < 0 ? -fractionalPart : fractionalPart
    let fractionalDescription = "\(fractionalMagnitude)"
    let fractionalDigits = fractionalDescription.drop(while: { $0 != "." }).dropFirst()
    let fractionalWords = fractionalDigits.map { toCardinal(Int(String($0)) ?? 0) }.joined(separator: " ")
    return "\(integerWords) \(pointWord) \(fractionalWords)"
  }
  
  /// Converts a number representing year, oridnal number or a decimal (integer numbers included) to words
  func convert(_ number: Decimal, to format: ConversionFormat = .decimal) -> String {
    switch format {
    case .ordinal:
      return toOrdinal(number)
    case .ordinalNum:
      return toOrdinalNum(number)
    case .year:
      return toYear(number)
    case .decimal:
      return toDecimal(number)
    }
  }
}
