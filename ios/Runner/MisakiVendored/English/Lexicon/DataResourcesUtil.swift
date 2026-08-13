import Foundation

final class DataResourcesUtil {
    private init() {}
    
    static func loadGold(british: Bool) -> [String: Any] {
        let filename = british ? "gb_gold" : "us_gold"
        
      guard let url = Bundle.main.url(forResource: filename, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return [:]
        }
      
        return json
    }
    
    static func loadSilver(british: Bool) -> [String: Any] {
      let filename = british ? "gb_silver" : "us_silver"

      // No subdirectory: Xcode's Copy Bundle Resources flattens these files
      // into the bundle root (loadGold above already looks there). The
      // subdirectory:"Resources" lookup silently returned nil, so the ~3 MB
      // silver pronunciation dictionary NEVER loaded — every word not in
      // gold fell through to a full BART forward pass instead of a lookup.
      guard let url = Bundle.main.url(forResource: filename, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
          NSLog("DataResources: \(filename).json missing from bundle — silver lexicon disabled")
          return [:]
      }
            
      return json
    }
}
