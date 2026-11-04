import Core
import Foundation
import Testing

@Test func unknownCapacityDoesNotAppearAsAvailableZero() {
  #expect(SpaceSummary.subtitle(SpaceInfo(total: nil, used: nil)) == L("已连接"))
  #expect(SpaceSummary.mounted(nil) == L("已挂载"))
  let zero = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
  #expect(
    SpaceSummary.subtitle(SpaceInfo(total: 0, used: 0))
      == String.localizedStringWithFormat(L("已连接 · 可用 %@"), zero))
  #expect(SpaceSummary.mounted(0) == String.localizedStringWithFormat(L("已挂载 · 可用 %@"), zero))
}

@Test func capacitySummaryShowsOnlyKnownValues() {
  let used = ByteCountFormatter.string(fromByteCount: 20_000, countStyle: .file)
  let total = ByteCountFormatter.string(fromByteCount: 10_000, countStyle: .file)
  #expect(
    SpaceSummary.subtitle(SpaceInfo(total: nil, used: 20_000))
      == String.localizedStringWithFormat(L("已连接 · 已用 %@"), used))
  #expect(
    SpaceSummary.subtitle(SpaceInfo(total: 10_000, used: nil))
      == String.localizedStringWithFormat(L("已连接 · 总容量 %@"), total))
  #expect(
    SpaceSummary.subtitle(SpaceInfo(total: 10_000, used: 20_000))
      == String.localizedStringWithFormat(L("已连接 · 已用 %@ / 总容量 %@"), used, total))
  #expect(
    SpaceSummary.subtitle(SpaceInfo(total: nil, used: nil, available: 10_000))
      == String.localizedStringWithFormat(L("已连接 · 可用 %@"), total))
}
