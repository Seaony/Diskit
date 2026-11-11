import Foundation

public enum RemoteXattrPolicy: Sendable {
  case set, create, replace, remove
}

extension RemoteVolumeBackend {
  public func getXattr(named name: Data, of path: RemotePath) async throws -> Data {
    try await perform("getxattr", path: path) { backend in
      return try backend.overlay.getXattr(named: name, of: path)
    }
  }

  public func setXattr(
    named name: Data, to value: Data?, on path: RemotePath, policy: RemoteXattrPolicy
  ) async throws {
    try await perform("setxattr", path: path) { backend in
      try backend.overlay.setXattr(named: name, to: value, on: path, policy: policy)
    }
  }

  public func listXattrs(of path: RemotePath) async throws -> [Data] {
    try await perform("listxattrs", path: path) { backend in
      return try backend.overlay.listXattrs(of: path)
    }
  }
}
