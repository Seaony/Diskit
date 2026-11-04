import Core
import ImageCaptureCore

@MainActor enum RicohHardwareSelection {
  static func nativeFiles(_ files: [any RicohHardwareFile]) throws -> [ICCameraFile] {
    try files.map { file in
      guard let value = file as? ICRicohFile else { throw RemoteError.protocolError }
      return value.file
    }
  }
}
