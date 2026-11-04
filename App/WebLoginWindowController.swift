import AppKit
import Core
import SwiftUI

@MainActor final class WebLoginWindowController: NSObject, NSWindowDelegate, WebLoginAuthorizing {
  private var window: NSWindow?
  private var state: WebLoginState?
  private var continuation: CheckedContinuation<WebLoginCredentials, Error>?

  func authorize(
    service: WebLoginService, options: RuntimeOptions,
    validate: @escaping @MainActor (WebLoginCredentials) async throws -> Void
  ) async throws -> WebLoginCredentials {
    try Task.checkCancellation()
    cancel()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        let state = WebLoginState(service: service, options: options, validate: validate) {
          [weak self] result in
          self?.finish(result)
        }
        self.state = state
        let content = WebLoginView(state: state, cancel: { [weak self] in self?.cancel() })
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
          defer: false)
        window.title = LF("登录%@", service.name)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = NSColor(KayoiTheme.background)
        window.contentMinSize = NSSize(width: 560, height: 520)
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        if options.isDemo {
          window.center()
        } else {
          let name = "KayoiWebLogin." + service.rawValue
          window.setFrameAutosaveName(name)
          if !window.setFrameUsingName(name) { window.center() }
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }

  func cancel() { finish(.failure(CancellationError())) }

  func windowWillClose(_ notification: Notification) { cancel() }

  private func finish(_ result: Result<WebLoginCredentials, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    state?.stop()
    state = nil
    window?.delegate = nil
    window?.close()
    window = nil
    continuation.resume(with: result)
  }
}
