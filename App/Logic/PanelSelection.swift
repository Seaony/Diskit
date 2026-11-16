import Foundation

struct PanelSelection {
  struct ScrollRequest: Equatable {
    let id = UUID()
    let connectionID: UUID
  }
  private(set) var id: UUID?
  private(set) var scrollRequest: ScrollRequest?

  mutating func select(_ id: UUID?, reveal: Bool) {
    self.id = id
    scrollRequest = reveal ? id.map { ScrollRequest(connectionID: $0) } : nil
  }

  // 方向键：还没选中时先选第一个；上下换行时没有目标行就停在原地，不横跳到隔壁格子
  mutating func move(_ offset: Int, in ids: [UUID]) {
    guard !ids.isEmpty else { return }
    guard let current = id.flatMap({ ids.firstIndex(of: $0) }) else {
      select(ids[0], reveal: true)
      return
    }
    if abs(offset) > 1 && !ids.indices.contains(current + offset) { return }
    select(ids[min(max(current + offset, 0), ids.count - 1)], reveal: true)
  }

  // 选中的位置被删掉后不再选中别的，免得回车、删除键作用到没看到的位置上
  mutating func keep(in ids: [UUID]) {
    if let id, !ids.contains(id) { select(nil, reveal: false) }
  }
}
