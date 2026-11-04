import AppKit

extension AppModel {
  func selectDemoEditorState(_ state: DemoEditorState) {
    guard options.isDemo else { return }
    demoEditorStateOverride = state
    demoEditorRevision += 1
  }

  func selectDemoAppearance(
    _ value: String,
    apply: (NSAppearance.Name) -> Void = {
      NSApplication.shared.appearance = NSAppearance(named: $0)
    }
  ) {
    guard options.isDemo, value == "light" || value == "dark" else { return }
    demoAppearanceOverride = value
    apply(value == "dark" ? .darkAqua : .aqua)
  }
}
