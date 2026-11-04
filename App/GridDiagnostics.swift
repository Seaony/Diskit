import Foundation
import SwiftUI

struct GridMeasurement: Codable, Equatable, Sendable {
  let name: String
  let area: String
  let edge: String?
  let isArea: Bool
  let inset: Double
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

private struct GridMeasurementsKey: PreferenceKey {
  static let defaultValue: [GridMeasurement] = []
  static func reduce(value: inout [GridMeasurement], nextValue: () -> [GridMeasurement]) {
    value.append(contentsOf: nextValue())
  }
}

private struct GridMarker: ViewModifier {
  let name: String
  let area: String
  let edge: String?
  let isArea: Bool
  let inset: CGFloat
  func body(content: Content) -> some View {
    content.background {
      if RuntimeOptions.current.isDemo {
        GeometryReader { geometry in
          let frame = geometry.frame(in: .global)
          Color.clear.preference(key: GridMeasurementsKey.self, value: [GridMeasurement(
            name: name, area: area, edge: edge, isArea: isArea, inset: inset,
            x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)])
        }
      }
    }
  }
}

private actor GridLayoutWriter {
  static let shared = GridLayoutWriter()
  func write(_ measurements: [GridMeasurement], page: String, mode: String, directory: String) {
    do {
      let directory = URL(filePath: directory, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(measurements).write(
        to: directory.appending(path: "\(page)-\(mode)-layout.json"), options: .atomic)
    } catch {
      NSLog("无法写入布局检查文件：%@", error.localizedDescription)
    }
  }
}

private struct GridDiagnostics: ViewModifier {
  let page: String
  @Environment(\.colorScheme) private var scheme
  @State private var measurements: [GridMeasurement] = []
  private var enabled: Bool { RuntimeOptions.current.isDemo }
  func body(content: Content) -> some View {
    content
      .onPreferenceChange(GridMeasurementsKey.self) { values in
        guard enabled else { return }
        measurements = values
        guard let directory = RuntimeOptions.current.layoutDirectory, !directory.isEmpty else { return }
        let mode = scheme == .dark ? "dark" : "light"
        Task { await GridLayoutWriter.shared.write(values, page: page, mode: mode, directory: directory) }
      }
      .overlay {
        if enabled && RuntimeOptions.current.showsLayoutGrid {
          GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            Canvas { context, size in
              var grid = Path()
              for x in stride(from: 0.0, through: size.width, by: 8) {
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
              }
              for y in stride(from: 0.0, through: size.height, by: 8) {
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
              }
              context.stroke(grid, with: .color(KayoiTheme.border.opacity(0.25)), lineWidth: 1)
              for item in measurements {
                let rect = CGRect(x: item.x - origin.x, y: item.y - origin.y, width: item.width, height: item.height)
                let color = KayoiTheme.locationColor(item.isArea ? "blue" : "pink")
                context.stroke(Path(rect), with: .color(color), lineWidth: 1)
                if item.isArea && item.inset > 0 {
                  context.stroke(Path(rect.insetBy(dx: item.inset, dy: item.inset)), with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                context.draw(Text(item.name).font(.caption2).foregroundStyle(color), at: rect.origin, anchor: .topLeading)
              }
            }
          }.allowsHitTesting(false).accessibilityHidden(true)
        }
      }
  }
}

extension View {
  func gridArea(_ name: String, inset: CGFloat = 0) -> some View {
    modifier(GridMarker(name: name, area: name, edge: nil, isArea: true, inset: inset))
  }
  func gridProbe(_ name: String, area: String, edge: String? = "lead") -> some View {
    modifier(GridMarker(name: name, area: area, edge: edge, isArea: false, inset: 0))
  }
  func gridDiagnostics(_ page: String) -> some View { modifier(GridDiagnostics(page: page)) }
}
