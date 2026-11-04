import AppKit
import Testing

@Test func operationAlertButtonsMatchDisplayedOrder() {
  #expect(OperationAlertAction.resolve(.alertFirstButtonReturn, hasRetry: true) == .retry)
  #expect(OperationAlertAction.resolve(.alertSecondButtonReturn, hasRetry: true) == .dismiss)
  #expect(OperationAlertAction.resolve(.alertThirdButtonReturn, hasRetry: true) == .copy)
  #expect(OperationAlertAction.resolve(.alertFirstButtonReturn, hasRetry: false) == .dismiss)
  #expect(OperationAlertAction.resolve(.alertSecondButtonReturn, hasRetry: false) == .copy)
  #expect(OperationAlertAction.resolve(.abort, hasRetry: true) == .dismiss)
}
