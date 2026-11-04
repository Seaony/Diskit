import AppKit
import SwiftUI

@MainActor final class WindowCoordinator {
  private struct Entry {
    weak var window: NSWindow?
    let role: String
  }
  private var windows: [ObjectIdentifier: Entry] = [:]
  private var observers: [NSObjectProtocol] = []

  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    for name in [
      NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          guard let window = note.object as? NSWindow else { return }
          let notificationName = note.name
          MainActor.assumeIsolated {
            guard let self else { return }
            if notificationName == NSWindow.didBecomeKeyNotification,
              window.styleMask.contains(.titled), window.level < .statusBar
            {
              if self.windows[ObjectIdentifier(window)] == nil {
                self.register(window, role: "auxiliary")
              }
              self.recover(window)
            }
            self.refreshActivation(
              excluding: notificationName == NSWindow.willCloseNotification ? window : nil)
          }
        })
    }
    observers.append(
      center.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          for entry in self.windows.values { if let window = entry.window { self.recover(window) } }
        }
      })
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    windows.removeAll()
  }

  func prepareToOpen() {
    start()
    NSApplication.shared.setActivationPolicy(.regular)
  }

  func register(_ window: NSWindow, role: String) {
    start()
    windows = windows.filter { $0.value.window != nil }
    windows[ObjectIdentifier(window)] = Entry(window: window, role: role)
    recover(window)
    if window.isVisible || window.isMiniaturized { refreshActivation() }
  }

  func showExistingWindow() -> Bool {
    guard
      let window = windows.values.compactMap(\.window)
        .first(where: { $0.isVisible || $0.isMiniaturized })
    else { return false }
    prepareToOpen()
    recover(window)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
    return true
  }

  private func refreshActivation(excluding closing: NSWindow? = nil) {
    let hasWindow = windows.values.contains { entry in
      guard let window = entry.window, window !== closing else { return false }
      return window.isVisible || window.isMiniaturized
    }
    NSApplication.shared.setActivationPolicy(hasWindow ? .regular : .accessory)
  }

  private func recover(_ window: NSWindow) {
    let screens = NSScreen.screens
    let preferred = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let frame = WindowPlacement.visibleFrame(
      window.frame, screens: screens.map(\.visibleFrame), preferred: preferred?.visibleFrame)
    if frame != window.frame { window.setFrame(frame, display: true, animate: false) }
  }
}

struct WindowRegistration: NSViewRepresentable {
  let coordinator: WindowCoordinator
  let role: String

  func makeNSView(context: Context) -> RegistrationView {
    let view = RegistrationView()
    view.coordinator = coordinator
    view.role = role
    return view
  }

  func updateNSView(_ view: RegistrationView, context: Context) {
    view.coordinator = coordinator
    view.role = role
    if let window = view.window { coordinator.register(window, role: role) }
  }

  @MainActor final class RegistrationView: NSView {
    weak var coordinator: WindowCoordinator?
    var role = ""
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { coordinator?.register(window, role: role) }
    }
  }
}
