import Foundation

enum PairingDigits {
  static func normalized(_ value: String) -> String {
    String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
  }
  static func replacing(_ input: String, at index: Int, in current: [String]) -> [String] {
    var digits = Array((current + Array(repeating: "", count: 6)).prefix(6))
    let value = normalized(input)
    guard (0..<6).contains(index) else { return digits }
    if value.isEmpty {
      digits[index] = ""
      return digits
    }
    for (offset, character) in value.enumerated() where index + offset < 6 {
      digits[index + offset] = String(character)
    }
    return digits
  }
}
