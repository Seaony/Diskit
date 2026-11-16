import Core
import Testing

@Test func duplicateNamesFollowFinderStyleAndStayStable() {
  let entries = [
    DuplicateNames.Entry(id: "b", name: "照片.jpg", isDirectory: false),
    DuplicateNames.Entry(id: "a", name: "照片.jpg", isDirectory: false),
    DuplicateNames.Entry(id: "c", name: "照片 (2).jpg", isDirectory: false),
    DuplicateNames.Entry(id: "d", name: "资料", isDirectory: true),
    DuplicateNames.Entry(id: "e", name: "资料", isDirectory: true),
    DuplicateNames.Entry(id: "f", name: "唯一.txt", isDirectory: false),
  ]
  let names = DuplicateNames.displayNames(entries)
  #expect(names["a"] == "照片.jpg")
  #expect(names["c"] == "照片 (2).jpg")
  #expect(names["b"] == "照片 (3).jpg")
  #expect(names["d"] == "资料")
  #expect(names["e"] == "资料 (2)")
  #expect(names["f"] == "唯一.txt")
  #expect(Set(names.values).count == entries.count)
  // 列目录顺序变了，对应关系不变
  #expect(DuplicateNames.displayNames(entries.reversed()) == names)
}

@Test func duplicateNamesHandleNamesWithoutExtension() {
  let names = DuplicateNames.displayNames([
    DuplicateNames.Entry(id: "1", name: ".env", isDirectory: false),
    DuplicateNames.Entry(id: "2", name: ".env", isDirectory: false),
    DuplicateNames.Entry(id: "3", name: "README", isDirectory: false),
    DuplicateNames.Entry(id: "4", name: "README", isDirectory: false),
  ])
  #expect(names["2"] == ".env (2)")
  #expect(names["4"] == "README (2)")
}

@Test func duplicateNamesCountRepeatedIDsOnce() {
  let names = DuplicateNames.displayNames([
    DuplicateNames.Entry(id: "1", name: "a.txt", isDirectory: false),
    DuplicateNames.Entry(id: "1", name: "a.txt", isDirectory: false),
  ])
  #expect(names == ["1": "a.txt"])
}

@Test func duplicateNameMemoryKeepsNamesWhenASiblingIsDeleted() {
  let memory = DuplicateNameMemory()
  func entry(_ id: String, _ name: String = "a.txt") -> DuplicateNames.Entry {
    DuplicateNames.Entry(id: id, name: name, isDirectory: false)
  }
  let first = memory.assign([entry("1"), entry("2"), entry("3"), entry("9", "a (2).txt")], in: "/")
  #expect(first == ["1": "a.txt", "9": "a (2).txt", "2": "a (3).txt", "3": "a (4).txt"])
  // 删掉第一个后，剩下的不重新编号；Finder 再按旧名字找第二个时还是同一个文件
  let second = memory.assign([entry("2"), entry("3"), entry("9", "a (2).txt")], in: "/")
  #expect(second["2"] == "a (3).txt")
  #expect(second["3"] == "a (4).txt")
  // 新传上来的同名文件拿空出来的原名
  let third = memory.assign([entry("2"), entry("3"), entry("9", "a (2).txt"), entry("0")], in: "/")
  #expect(third["0"] == "a.txt")
  // 服务器上改了名的按新名字重新分配
  let renamed = memory.assign([entry("2", "b.txt"), entry("3")], in: "/")
  #expect(renamed["2"] == "b.txt")
  // 别的目录互不影响
  #expect(memory.assign([entry("1")], in: "/other") == ["1": "a.txt"])
}
