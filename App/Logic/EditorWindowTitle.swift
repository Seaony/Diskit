import Core

enum EditorWindowTitle {
  static func text(name: String, isSaved: Bool) -> String {
    isSaved ? LF("编辑“%@”", name) : L("添加位置")
  }

  static func synchronize(_ title: String, current: String, set: (String) -> Void) {
    if current != title { set(title) }
  }
}
