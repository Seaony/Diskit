import OSLog

public enum PackageDiagnostics {
  public static func failure(
    _ error: Error, category: DiagnosticCategory, operation: DiagnosticOperation
  ) {
    guard let event = SafeDiagnostic(category: category, operation: operation, error: error) else {
      return
    }
    emit(event)
  }

  static func emit(_ event: SafeDiagnostic) {
    let logger = Logger(subsystem: "com.seaony.Kayoi", category: event.category.rawValue)
    logger.error("操作失败：\(event.message, privacy: .public)")
  }
}
