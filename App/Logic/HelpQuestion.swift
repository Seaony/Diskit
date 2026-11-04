struct HelpQuestion: Identifiable {
  let id: String
  let title: String
  let answer: String
  init(_ id: String, _ title: String, _ answer: String) {
    self.id = id
    self.title = title
    self.answer = answer
  }
}
