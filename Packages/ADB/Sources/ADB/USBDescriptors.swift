import Core
import Foundation

struct USBBulkEndpoints: Equatable {
  let input: Int
  let output: Int
  let packetSize: Int

  static func parse(_ data: Data, interface: UInt8, alternate: UInt8) throws -> Self {
    let bytes = Array(data)
    guard bytes.count >= 9, bytes[0] >= 9, bytes[1] == 2 else { throw RemoteError.protocolError }
    let length = Int(bytes[2]) | Int(bytes[3]) << 8
    guard length == bytes.count else { throw RemoteError.protocolError }
    var position = 0
    var selected = false
    var input: Int?
    var output: Int?
    var packetSize = 0
    while position < length {
      guard position + 2 <= length else { throw RemoteError.protocolError }
      let size = Int(bytes[position])
      let type = bytes[position + 1]
      guard size >= 2, position + size <= length else { throw RemoteError.protocolError }
      if type == 4 {
        guard size >= 9 else { throw RemoteError.protocolError }
        selected = bytes[position + 2] == interface && bytes[position + 3] == alternate
        if selected {
          guard bytes[position + 5] == 0xff, bytes[position + 6] == 0x42,
            bytes[position + 7] == 1
          else { throw RemoteError.protocolError }
        }
      }
      if selected, type == 5 {
        guard size >= 7 else { throw RemoteError.protocolError }
        if bytes[position + 3] & 3 == 2 {
          let address = Int(bytes[position + 2])
          let size = (Int(bytes[position + 4]) | Int(bytes[position + 5]) << 8) & 0x7ff
          guard address & 0x0f != 0, size > 0 else { throw RemoteError.protocolError }
          if address & 0x80 != 0 {
            guard input == nil else { throw RemoteError.protocolError }
            input = address
          } else {
            guard output == nil else { throw RemoteError.protocolError }
            output = address
            packetSize = size
          }
        }
      }
      position += size
    }
    guard let input, let output else { throw RemoteError.protocolError }
    return Self(input: input, output: output, packetSize: packetSize)
  }
}
