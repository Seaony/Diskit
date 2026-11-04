import Foundation

struct Measurement: Decodable {
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
func nearGrid(_ value: Double, step: Double) -> Bool {
  abs(value / step - (value / step).rounded()) < 0.02
}
var failed = false
let paths = Array(CommandLine.arguments.dropFirst())
if paths.isEmpty {
  print("请传入演示模式导出的 *-layout.json")
  exit(1)
}
for path in paths {
  do {
    let values = try JSONDecoder().decode([Measurement].self, from: Data(contentsOf: URL(filePath: path)))
    let areas = values.filter(\.isArea)
    let probes = values.filter { !$0.isArea && $0.width > 0 && $0.height > 0 }
    var errors: [String] = []
    if probes.isEmpty { errors.append("没有布局探针") }
    for probe in probes {
      guard let area = areas.first(where: { $0.name == probe.area }) else {
        errors.append("\(probe.name)：缺少区域 \(probe.area)"); continue
      }
      if !nearGrid(probe.x, step: 0.5) || !nearGrid(probe.y, step: 0.5) {
        errors.append("\(probe.name)：边缘未落在整点或半点")
      }
      if !nearGrid(probe.x - area.x, step: 4) {
        errors.append("\(probe.name)：距区域左缘 \(probe.x - area.x) pt，不在 4 pt 网格")
      }
      if probe.x < area.x + area.inset - 0.5 || probe.x + probe.width > area.x + area.width - area.inset + 0.5 {
        errors.append("\(probe.name)：越过区域左右内边距")
      }
    }
    for area in areas {
      let members = probes.filter { $0.area == area.name }
      let groups = Dictionary(grouping: members.filter { $0.edge != nil }, by: { $0.edge! })
      for (edge, members) in groups {
        let sorted = members.sorted { $0.y < $1.y }
        if let first = sorted.first, sorted.contains(where: { abs($0.x - first.x) > 0.5 }) {
          errors.append("\(area.name)/\(edge)：列的左缘未对齐")
        }
        for (above, below) in zip(sorted, sorted.dropFirst()) {
          let gap = below.y - above.y - above.height
          if gap >= -0.5 && !nearGrid(gap, step: 4) {
            errors.append("\(above.name) → \(below.name)：间隔 \(gap) pt，不在 4 pt 网格")
          }
        }
      }
      for (index, first) in members.enumerated() {
        for second in members.dropFirst(index + 1) {
          let horizontal = min(first.x + first.width, second.x + second.width) - max(first.x, second.x)
          let vertical = min(first.y + first.height, second.y + second.height) - max(first.y, second.y)
          if horizontal > 0.5 && vertical > 0.5 { errors.append("\(first.name) 与 \(second.name) 重叠") }
        }
      }
    }
    if errors.isEmpty { print("PASS \(path): \(probes.count) probes in \(areas.count) areas") }
    else { failed = true; print("FAIL \(path)\n" + errors.map { "  - " + $0 }.joined(separator: "\n")) }
  } catch { failed = true; print("FAIL \(path): \(error)") }
}
exit(failed ? 1 : 0)
