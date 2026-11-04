import Core
import CryptoKit
import Foundation

struct TianyiUploadPart: Equatable, Sendable {
  let number: Int
  let offset: Int64
  let length: Int64
  let digest: Data

  var info: String {
    "\(number)-\(digest.base64EncodedString())"
  }
}

struct TianyiUploadPlan: Equatable, Sendable {
  let fileMD5: String
  let sliceMD5: String
  let sliceSize: Int64
  let parts: [TianyiUploadPart]

  static func make(from file: URL, size: Int64, requestedSliceSize: Int64?) throws -> Self {
    guard size >= 0 else { throw RemoteError.posix(EINVAL) }
    let sliceSize = try sliceSize(for: size, requested: requestedSliceSize)
    guard let handle = try? FileHandle(forReadingFrom: file) else {
      throw RemoteError.posix(EIO)
    }
    defer { try? handle.close() }
    let count = max(1, Int((size + sliceSize - 1) / sliceSize))
    var parts: [TianyiUploadPart] = []
    var whole = Insecure.MD5()
    parts.reserveCapacity(count)
    for index in 0..<count {
      try Task.checkCancellation()
      let offset = Int64(index) * sliceSize
      let length = min(sliceSize, max(0, size - offset))
      let data: Data
      if length == 0 {
        data = Data()
      } else {
        data = try readExactly(handle, count: Int(length))
      }
      whole.update(data: data)
      parts.append(
        TianyiUploadPart(
          number: index + 1, offset: offset, length: length,
          digest: Data(TianyiCrypto.hashMD5Data(data))))
    }
    let fileMD5 = Data(whole.finalize()).map { String(format: "%02X", $0) }.joined()
    let sliceMD5: String
    if parts.count == 1 {
      sliceMD5 = fileMD5
    } else {
      sliceMD5 = TianyiCrypto.md5Hex(
        Data(
          parts.map { $0.digest.map { String(format: "%02X", $0) }.joined() }
            .joined(separator: "\n").utf8))
    }
    return TianyiUploadPlan(
      fileMD5: fileMD5, sliceMD5: sliceMD5, sliceSize: sliceSize, parts: parts)
  }

  static func sliceSize(for size: Int64, requested: Int64?) throws -> Int64 {
    let base: Int64 = 10 * 1024 * 1024
    let value = requested ?? base
    guard value > 0 else { throw RemoteError.posix(EINVAL) }
    if requested != nil { return value }
    if size > base * 2 * 999 {
      let unit = size / 1999
      let blocks = (unit + base - 1) / base
      return max(5 * base, blocks * base)
    }
    if size > base * 999 { return 2 * base }
    return base
  }

  func data(for part: TianyiUploadPart, in file: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(part.offset))
    if part.length == 0 { return Data() }
    return try Self.readExactly(handle, count: Int(part.length))
  }

  private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
      try Task.checkCancellation()
      guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
        throw RemoteError.posix(EIO)
      }
      data.append(chunk)
    }
    return data
  }
}

extension TianyiCrypto {
  static func hashMD5Data(_ data: Data) -> Data {
    Data(Insecure.MD5.hash(data: data))
  }
}
