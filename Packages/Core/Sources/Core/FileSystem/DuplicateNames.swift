import Foundation

// 不少网盘允许同一目录里有同名文件，而 Finder 里一个目录不能有两个同名项。
// 这里给重名的条目分配和 Finder 一样的「名称 (2).扩展名」：按 id 排序，最小的保留原名，
// 其余依次编号并跳过已被占用的名字。按 id 排序是为了每次列目录得到的对应关系都一样。
public enum DuplicateNames {
  public struct Entry: Sendable {
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public init(id: String, name: String, isDirectory: Bool) {
      self.id = id
      self.name = name
      self.isDirectory = isDirectory
    }
  }

  // 返回 id → 在 Finder 里显示的名字；没有重名时就是原名
  public static func displayNames(_ entries: [Entry]) -> [String: String] {
    // 翻页期间目录有变动时，同一个条目可能出现两次，只算一次
    var seen = Set<String>()
    let entries = entries.filter { seen.insert($0.id).inserted }
    var result: [String: String] = [:]
    var taken = Set<String>()
    let groups = Dictionary(grouping: entries, by: \.name)
    for entry in entries where groups[entry.name]?.count == 1 {
      result[entry.id] = entry.name
      taken.insert(entry.name)
    }
    for name in groups.keys.sorted() {
      guard let group = groups[name], group.count > 1 else { continue }
      let ordered = group.sorted { $0.id < $1.id }
      var number = 2
      for (index, entry) in ordered.enumerated() {
        if index == 0, !taken.contains(name) {
          result[entry.id] = name
          taken.insert(name)
          continue
        }
        var candidate = numbered(name, number, isDirectory: entry.isDirectory)
        while taken.contains(candidate) {
          number += 1
          candidate = numbered(name, number, isDirectory: entry.isDirectory)
        }
        result[entry.id] = candidate
        taken.insert(candidate)
        number += 1
      }
    }
    return result
  }

  static func numbered(_ name: String, _ number: Int, isDirectory: Bool) -> String {
    let ext = (name as NSString).pathExtension
    guard !isDirectory, !ext.isEmpty, name.count > ext.count + 1 else { return "\(name) (\(number))" }
    let stem = String(name.dropLast(ext.count + 1))
    return "\(stem) (\(number)).\(ext)"
  }
}

// 记住每个目录里重名条目分到的名字。重新列目录时还在的条目沿用原名字，
// 不会因为别的同名文件被删掉而重新编号：Finder 多选删除时，第二个文件仍按旧名字找过来，
// 编号一变就会删到没选中的那个。每个网盘连接各持有一个。
public final class DuplicateNameMemory: @unchecked Sendable {
  private let lock = NSLock()
  // 目录 → 条目 id → (服务器上的名字, 显示的名字)
  private var folders: [String: [String: (name: String, display: String)]] = [:]

  public init() {}

  public func assign(_ entries: [DuplicateNames.Entry], in folder: String) -> [String: String] {
    lock.withLock {
      var seen = Set<String>()
      let entries = entries.filter { seen.insert($0.id).inserted }
      let previous = folders[folder] ?? [:]
      var result: [String: String] = [:]
      var taken = Set<String>()
      // 先让记得的条目沿用原名字；服务器上改过名的不算
      for entry in entries.sorted(by: { $0.id < $1.id }) {
        guard let remembered = previous[entry.id], remembered.name == entry.name,
          !taken.contains(remembered.display)
        else { continue }
        result[entry.id] = remembered.display
        taken.insert(remembered.display)
      }
      // 其余的：名字不重复的先拿原名，再给重名的按 id 顺序编号，跳过已被占用的名字
      let groups = Dictionary(grouping: entries, by: \.name)
      let rest = entries.filter { result[$0.id] == nil }.sorted {
        (groups[$0.name]?.count == 1 ? 0 : 1, $0.id) < (groups[$1.name]?.count == 1 ? 0 : 1, $1.id)
      }
      for entry in rest {
        if !taken.contains(entry.name) {
          result[entry.id] = entry.name
          taken.insert(entry.name)
          continue
        }
        var number = 2
        var candidate = DuplicateNames.numbered(entry.name, number, isDirectory: entry.isDirectory)
        while taken.contains(candidate) {
          number += 1
          candidate = DuplicateNames.numbered(entry.name, number, isDirectory: entry.isDirectory)
        }
        result[entry.id] = candidate
        taken.insert(candidate)
      }
      // 只留这次还在的条目，记忆不会越积越多
      folders[folder] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.id, (name: $0.name, display: result[$0.id]!)) })
      return result
    }
  }
}
