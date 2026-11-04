enum ControlFocus {
  static func isFocused(inherited: Bool, explicit: Bool?) -> Bool { explicit ?? inherited }
}
