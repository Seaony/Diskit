struct HelpParagraph: Identifiable {
  let id: String
  let text: String
  init(_ id: String, _ text: String) {
    self.id = id
    self.text = text
  }
}
