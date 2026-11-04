import AppKit
import SwiftUI

private struct AppearanceEvidence: Codable, Sendable {
  let appearance: String
  let colorScheme: String
  let contrast: String
  let borderLinearRGB: [Float]
}

private actor AppearanceEvidenceWriter {
  static let shared = AppearanceEvidenceWriter()
  func write(_ evidence: AppearanceEvidence, page: String, directory: String) throws {
    let directory = URL(filePath: directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(evidence).write(to: directory.appending(path: "\(page)-appearance.json"), options: .atomic)
  }
}

private struct DemoAppearanceEvidence: ViewModifier {
  let page: String
  @Environment(\.self) private var environment
  func body(content: Content) -> some View {
    content.task(id: "\(environment.colorScheme)-\(environment.colorSchemeContrast)") {
      let options = RuntimeOptions.current
      guard options.isDemo, let directory = options.layoutDirectory else { return }
      let border = KayoiTheme.border.resolve(in: environment)
      let evidence = AppearanceEvidence(
        appearance: NSApp.effectiveAppearance.name.rawValue,
        colorScheme: environment.colorScheme == .dark ? "dark" : "light",
        contrast: environment.colorSchemeContrast == .increased ? "increased" : "standard",
        borderLinearRGB: [border.linearRed, border.linearGreen, border.linearBlue])
      do { try await AppearanceEvidenceWriter.shared.write(evidence, page: page, directory: directory) }
      catch { NSLog("无法写入外观检查文件：%@", error.localizedDescription) }
    }
  }
}

extension View {
  func demoAppearanceEvidence(_ page: String) -> some View {
    modifier(DemoAppearanceEvidence(page: page))
  }
}
