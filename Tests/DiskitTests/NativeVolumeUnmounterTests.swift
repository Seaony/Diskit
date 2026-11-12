import DiskArbitration
import Foundation
import Synchronization
import Testing

private final class NativeUnmountFixture: Sendable {
  typealias Mount = NativeVolumeUnmounter.Mount
  struct State {
    var snapshots: [Mount?]
    var snapshotIndex = 0
    var fileManagerError: NSError?
    var diskArbitrationError: NSError?
    var events: [String] = []
    var diagnostics: [NSError] = []
  }
  let state: Mutex<State>

  init(snapshots: [Mount?], fileManagerError: NSError? = nil,
       diskArbitrationError: NSError? = nil) {
    state = Mutex(State(snapshots: snapshots, fileManagerError: fileManagerError,
                        diskArbitrationError: diskArbitrationError))
  }

  func operations() -> NativeVolumeUnmounter.Operations {
    NativeVolumeUnmounter.Operations(
      mount: { [self] _ in
        state.withLock { value in
          value.events.append("snapshot")
          let index = min(value.snapshotIndex, value.snapshots.count - 1)
          value.snapshotIndex += 1
          return value.snapshots[index]
        }
      },
      fileManager: { [self] _, completion in
        let error = state.withLock { value in
          value.events.append("fm")
          return value.fileManagerError
        }
        DispatchQueue.global().async {
          completion(error.map { .failure($0) } ?? .success(()))
        }
      },
      diskArbitration: { [self] _, completion in
        let error = state.withLock { value in
          value.events.append("da")
          return value.diskArbitrationError
        }
        DispatchQueue.global().async {
          completion(error.map { .failure($0) } ?? .success(()))
        }
      },
      recordFailure: { [self] error in state.withLock { $0.diagnostics.append(error as NSError) } })
  }

  func run() async -> Result<Void, Error> {
    await withCheckedContinuation { continuation in
      NativeVolumeUnmounter(operations: operations()).unmount(
        URL(filePath: "/Volumes/Fixture", directoryHint: .isDirectory)
      ) { continuation.resume(returning: $0) }
    }
  }
}

private func nativeUnmountMount(type: String = "diskit", source: String = "diskit-minio://fixture",
                                path: String = "/Volumes/Fixture", id: UInt8 = 1)
  -> NativeVolumeUnmounter.Mount {
  NativeVolumeUnmounter.Mount(type: type, source: source, path: path, filesystemID: Data([id]))
}

private func nativeUnmountReadFailure() -> NSError {
  NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
          userInfo: [NSUnderlyingErrorKey: POSIXError(.EIO)])
}

@Test func nativeUnmountFallsBackForTheSameDiskitVolumeAfterFileManagerReadFailure() async throws {
  let mount = nativeUnmountMount()
  let original = nativeUnmountReadFailure()
  let fixture = NativeUnmountFixture(snapshots: [mount, mount], fileManagerError: original)
  try await fixture.run().get()
  #expect(fixture.state.withLock { $0.events } == ["snapshot", "fm", "snapshot", "da"])
  #expect(fixture.state.withLock { $0.diagnostics.first } === original)
}

@Test func nativeUnmountKeepsFileManagerSuccessWithoutCallingDiskArbitration() async throws {
  let fixture = NativeUnmountFixture(snapshots: [nativeUnmountMount()])
  try await fixture.run().get()
  #expect(fixture.state.withLock { $0.events } == ["snapshot", "fm"])
  #expect(fixture.state.withLock { $0.diagnostics.isEmpty })
}

@Test(arguments: [
  NSError(domain: NSCocoaErrorDomain, code: NSFileManagerUnmountBusyError),
  NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
  NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)),
  NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
])
func nativeUnmountDoesNotFallbackForUnrelatedOrBusyErrors(original: NSError) async {
  let fixture = NativeUnmountFixture(snapshots: [nativeUnmountMount()], fileManagerError: original)
  if case .failure(let error) = await fixture.run() {
    #expect(error as NSError === original)
  } else {
    Issue.record("原生推出失败不能报告成功")
  }
  #expect(!fixture.state.withLock { $0.events.contains("da") })
}

@Test(arguments: [
  nativeUnmountMount(source: "diskit-minio://replacement"),
  nativeUnmountMount(path: "/Volumes/Replacement"),
  nativeUnmountMount(id: 2),
  nativeUnmountMount(type: "apfs"),
  nil,
] as [NativeVolumeUnmounter.Mount?])
func nativeUnmountRejectsChangedOrMissingMounts(current: NativeVolumeUnmounter.Mount?) async {
  let original = nativeUnmountReadFailure()
  let fixture = NativeUnmountFixture(snapshots: [nativeUnmountMount(), current],
                                    fileManagerError: original)
  if case .failure(let error) = await fixture.run() {
    #expect(error as NSError === original)
  } else {
    Issue.record("挂载项改变后不能推出其他卷")
  }
  #expect(!fixture.state.withLock { $0.events.contains("da") })
}

@Test(arguments: [nativeUnmountMount(type: "apfs"), nil] as [NativeVolumeUnmounter.Mount?])
func nativeUnmountDoesNotFallbackForUnrecognizedInitialMounts(initial: NativeVolumeUnmounter.Mount?) async {
  let original = nativeUnmountReadFailure()
  let fixture = NativeUnmountFixture(snapshots: [initial], fileManagerError: original)
  if case .failure(let error) = await fixture.run() {
    #expect(error as NSError === original)
  } else {
    Issue.record("没有真实 Diskit 挂载项时不能兜底推出")
  }
  #expect(!fixture.state.withLock { $0.events.contains("da") })
}

@Test func nativeUnmountKeepsBothFailuresAndDiskArbitrationBusyStatus() async {
  let mount = nativeUnmountMount()
  let original = nativeUnmountReadFailure()
  let busyStatus = DAReturn(truncatingIfNeeded: kDAReturnBusy)
  let busy = NativeVolumeUnmounter.diskArbitrationError(busyStatus)
  let fixture = NativeUnmountFixture(snapshots: [mount, mount], fileManagerError: original,
                                    diskArbitrationError: busy)
  if case .failure(let error) = await fixture.run() {
    let value = error as NSError
    #expect(value.domain == NSCocoaErrorDomain)
    #expect(value.code == NSFileManagerUnmountBusyError)
    let errors = value.underlyingErrors.map { $0 as NSError }
    #expect(errors.count == 2)
    #expect(errors.first === original)
    #expect(errors.last === busy)
    let raw = busy.underlyingErrors.first.map { $0 as NSError }
    #expect(raw?.domain == NSMachErrorDomain)
    #expect(raw?.code == Int(busyStatus))
  } else {
    Issue.record("DA 拒绝推出时不能报告成功")
  }
  #expect(fixture.state.withLock { $0.diagnostics.count } == 2)
}
