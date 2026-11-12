import Core
import Foundation

@MainActor struct AppModelDependencies {
  let location: any StorageLocation
  let secrets: any SecretStore
  let preferences: UserDefaults
  let smb: any SMBServing
  let httpTransport: any HTTPTransport
  let updates: UpdateController
  let system: AppSystemServices
  var info: [String: Any] = [:]
  var providerFactory: ((Connection) async throws -> any RemoteFileProvider)?
  var fileSystem: FileSystemMountService?
  var fileSystemStatePollWait: @MainActor () async throws -> Void = {
    try await Task.sleep(for: .seconds(2))
  }
}
