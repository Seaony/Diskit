import Foundation
import Network

public enum S3EndpointPolicy {
  public static func allows(_ endpoint: URL) -> Bool {
    guard let host = endpoint.host?.lowercased(), !host.isEmpty,
      endpoint.user == nil, endpoint.password == nil
    else { return false }
    if endpoint.scheme?.lowercased() == "https" { return true }
    guard endpoint.scheme?.lowercased() == "http" else { return false }
    let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if let ipv4 = IPv4Address(address) {
      let bytes = Array(ipv4.rawValue)
      guard address == bytes.map(String.init).joined(separator: ".") else { return false }
      return bytes[0] == 10 || bytes[0] == 127
        || (bytes[0] == 172 && (16...31).contains(bytes[1]))
        || (bytes[0] == 192 && bytes[1] == 168)
        || (bytes[0] == 169 && bytes[1] == 254)
    }
    if let ipv6 = IPv6Address(address) {
      let bytes = Array(ipv6.rawValue)
      return bytes == Array(repeating: 0, count: 15) + [1]
        || bytes[0] & 0xfe == 0xfc
        || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }
    return host.hasSuffix(".local")
      || (!host.contains(".") && !host.contains(":") && host.contains(where: { $0.isLetter }))
  }
}
