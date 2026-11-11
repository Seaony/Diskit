import ADB
import CameraUSB
import Core
import Foundation
import RicohGR

public enum CLIRunner {
  public static func run(_ arguments: [String]) async throws {
    let options = try CLIArguments(arguments)
    if options.command != "help", options.command != "devices" {
      try SharedStorageMigration.requireReady()
    }
    switch options.command {
    case "help":
      print(cliHelp)
      return
    case "devices":
      for device in ADBUSB.devices() { print("androidUSB\t\(device.serial)\t\(device.name)") }
      for device in try await RicohDiscovery.available() {
        print("ricohGR\t\(device.serial)\t\(device.name)")
      }
      for device in try await CameraUSBDiscovery.available() {
        print("cameraUSB\t\(device.serial)\t\(device.name)")
      }
      return
    case "pair":
      let address = try pairingAddress(options.operands[0], code: options.operands[1])
      print(try await ADBPairing.pair(host: address.0, port: address.1, code: options.operands[1]))
      return
    default: break
    }
    let storage = RuntimeStorage.current
    let connection = try loadConnection(options.connectionID, location: storage.location)
    let values = try CLIEnvironment.load(ProcessInfo.processInfo.environment)
    let provider = try await CLIProviderFactory.make(
      connection, values: values, secrets: storage.secrets)
    try await execute(
      options, provider: provider,
      text: { print($0) }, bytes: { try FileHandle.standardOutput.write(contentsOf: $0) },
      errors: { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) })
  }

  static func loadConnection(
    _ id: UUID?, location: any StorageLocation
  ) throws -> Connection {
    guard let connection = try ConnectionRepository(location: location).load().first(where: {
      $0.id == id
    }) else { throw RemoteError.invalidPath }
    return connection
  }

  static func pairingAddress(_ value: String, code: String) throws -> (String, UInt16) {
    guard let address = URLComponents(string: "adb://" + value), let host = address.host,
      !host.isEmpty,
      address.user == nil, address.password == nil, address.path.isEmpty, address.query == nil,
      address.fragment == nil,
      let raw = address.port, let port = UInt16(exactly: raw), port > 0,
      code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) })
    else { throw RemoteError.invalidPath }
    return (host, port)
  }

  static func execute(
    _ options: CLIArguments, provider: any RemoteFileProvider,
    text: @escaping @Sendable (String) -> Void, bytes: @escaping @Sendable (Data) throws -> Void,
    errors: @escaping @Sendable (String) -> Void
  ) async throws {
    let args = options.operands
    let capabilities = provider.capabilities
    if ["put", "mkdir"].contains(options.command), !capabilities.canWrite {
      throw RemoteError.posix(EROFS)
    }
    if options.command == "rm", !capabilities.canDelete { throw RemoteError.posix(EROFS) }
    if options.command == "mv" {
      let from = try RemotePath(args[0])
      let to = try RemotePath(args[1])
      let sameParent =
        from.value.split(separator: "/").dropLast() == to.value.split(separator: "/").dropLast()
      guard sameParent ? capabilities.canRename : capabilities.canMove else {
        throw RemoteError.posix(EROFS)
      }
    }
    do {
      try await provider.connect()
      switch options.command {
      case "ls":
        for item in try await provider.list(RemotePath(args[0]))
        where options.showHidden || !item.name.hasPrefix(".") { text(CLIOutput.listLine(item)) }
      case "stat":
        let item = try await provider.stat(RemotePath(args[0]))
        text(
          "\(item.path)\t\(item.size)\t\(item.modified)\t\(item.isDirectory ? "directory" : "file")"
        )
      case "mkdir": try await provider.makeDirectory(RemotePath(args[0]))
      case "rm": try await provider.remove(RemotePath(args[0]), recursive: options.recursive)
      case "mv": try await provider.move(RemotePath(args[0]), to: RemotePath(args[1]))
      case "put", "get":
        let progress = CLIProgress(output: errors)
        if options.command == "put" {
          try await CLITransfers.upload(
            provider, local: URL(fileURLWithPath: args[0]), remote: RemotePath(args[1]),
            report: progress.report)
        } else {
          try await CLITransfers.download(
            provider, remote: RemotePath(args[0]), local: URL(fileURLWithPath: args[1]),
            report: progress.report)
        }
      case "df":
        let space = try await provider.spaceInfo()
        text(
          "total=\(space.total.map(String.init) ?? "unknown") used=\(space.used.map(String.init) ?? "unknown") available=\(space.available.map(String.init) ?? "unknown")"
        )
      case "cat":
        let requested = capabilities.supportsRangeRead ? options.range : nil
        var offset = requested?.lowerBound ?? 0
        for try await chunk in try await provider.read(RemotePath(args[0]), range: requested) {
          try Task.checkCancellation()
          let (next, overflow) = offset.addingReportingOverflow(Int64(chunk.count))
          guard !overflow else { throw RemoteError.tooLarge }
          if let range = options.range {
            let lower = max(offset, range.lowerBound)
            let upper = min(next, range.upperBound)
            if lower < upper {
              try bytes(chunk.subdata(in: Int(lower - offset)..<Int(upper - offset)))
            }
            if next >= range.upperBound { break }
          } else {
            try bytes(chunk)
          }
          offset = next
        }
      default: throw RemoteError.unsupported
      }
      await provider.disconnect()
    } catch {
      PackageDiagnostics.failure(error, category: .devTool, operation: .command)
      await provider.disconnect()
      throw error
    }
  }
}
