public enum DiagnosticOperation: String, Sendable {
  case connect, disconnect, request, upload, download, fileOperation, snapshot, remove, mount, unmount,
    discover, command
}
