import CoreNative
import Darwin
import Foundation
import Testing

private func localSMBProcess(
  executable: String = "/bin/sh", script: String, password: String = "", capacity: Int = 131_072,
  timeout: TimeInterval = 2, io: UnsafePointer<diskit_smb_process_io>? = nil
) -> (error: Int32, status: Int32, output: String) {
  let strings = [executable, "-c", script].map { strdup($0)! }
  defer { for value in strings { free(value) } }
  let arguments: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) } + [nil]
  var output = [CChar](repeating: 0, count: max(1, capacity))
  var status: Int32 = -1
  let result = arguments.withUnsafeBufferPointer { pointers in
    if let io {
      return diskit_smb_process_with_io(
        executable, pointers.baseAddress!, password, &output, capacity, &status, timeout, io)
    }
    return diskit_smb_process(
      executable, pointers.baseAddress!, password, &output, capacity, &status, timeout)
  }
  return (
    result, status,
    String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  )
}

@Test func smbProcessDrainsTerminalAfterChildExit() {
  let result = localSMBProcess(
    executable: "/usr/bin/python3",
    script: "import os; os.write(1,b'A'*90000); os.write(1,b'END')")
  #expect(result.error == 0)
  #expect(result.status == 0)
  #expect(result.output.utf8.count == 90003)
  #expect(result.output.hasSuffix("END"))
}

@Test func smbProcessWritesPasswordOnlyToNonEchoingTerminal() {
  let result = localSMBProcess(
    executable: "/usr/bin/python3",
    script:
      "import os; os.write(1,b'Password:'); value=os.read(0,1024); os.write(1,b'OK' if value==b'local-test\\n' else b'BAD')",
    password: "local-test")
  #expect(result.error == 0)
  #expect(result.status == 0)
  #expect(result.output == "Password:OK")
}

private final class BlockedPasswordIO {
  var now: Double = 0
  var written = 0
  var blocked = false
}

@Test func smbProcessDeadlineIncludesBlockedPasswordInput() {
  let state = BlockedPasswordIO()
  var io = diskit_smb_process_io(
    context: Unmanaged.passUnretained(state).toOpaque(),
    now: { context in
      Unmanaged<BlockedPasswordIO>.fromOpaque(context!).takeUnretainedValue().now
    },
    poll: { _, descriptors, count, _ in
      // 提示到达前等真实终端事件；提示后由写入回调模拟缓冲区阻塞。
      if descriptors!.pointee.events & Int16(POLLOUT) != 0 {
        descriptors!.pointee.revents = Int16(POLLOUT)
        return 1
      }
      return Darwin.poll(descriptors, count, -1)
    },
    write: { context, descriptor, bytes, _ in
      let state = Unmanaged<BlockedPasswordIO>.fromOpaque(context!).takeUnretainedValue()
      if state.written == 0 {
        let sent = Darwin.write(descriptor, bytes, 1)
        if sent > 0 { state.written += sent }
        return sent
      }
      state.blocked = true
      state.now = 2
      errno = EAGAIN
      return -1
    })
  let result = withUnsafePointer(to: &io) {
    localSMBProcess(
      executable: "/usr/bin/python3",
      script: "import os,signal; os.write(1,b'Password:'); signal.pause()",
      password: "local-test", timeout: 2, io: $0)
  }
  #expect(state.written == 1)
  #expect(state.blocked)
  #expect(result.output == "Password:")
  #expect(result.error == ETIMEDOUT)
}

@Test func smbProcessPreservesExitStatusAndBoundsOutput() {
  let failure = localSMBProcess(script: "printf 'denied'; exit 17")
  #expect(failure.error == 0)
  #expect(failure.status == 17)
  #expect(failure.output == "denied")
  let overflow = localSMBProcess(script: "printf 'long output'", capacity: 4)
  #expect(overflow.error == ENOBUFS)
  let invalid = localSMBProcess(script: "exit 0", capacity: 0)
  #expect(invalid.error == EINVAL)
}
