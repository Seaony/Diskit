import Foundation

/// 各调用方传入自己的资源包，命令行工具也能读取包内翻译。
public enum DiskitLocalization {
  public static func text(_ key: String, bundle: Bundle, arguments: [CVarArg] = []) -> String {
    let environment = ProcessInfo.processInfo.environment
    let pseudo = environment["DISKIT_DEMO"] == "1" && environment["DISKIT_PSEUDO_LOCALE"] == "1"
    let selected: Bundle
    if pseudo, let path = bundle.path(forResource: "en", ofType: "lproj"), let english = Bundle(path: path) {
      selected = english
    } else {
      selected = bundle
    }
    let format = selected.localizedString(forKey: key, value: key, table: nil)
    let locale = pseudo ? Locale(identifier: "en") : Locale.current
    let value = arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    return pseudo ? expanded(value) : value
  }

  public static func expanded(_ value: String) -> String {
    guard !value.isEmpty else { return value }
    return "［" + value + String(repeating: "·", count: Int(ceil(Double(value.count) * 0.4))) + "］"
  }
}

public func L(_ value: String) -> String { DiskitLocalization.text(value, bundle: .module) }
public func LF(_ value: String, _ arguments: CVarArg...) -> String {
  DiskitLocalization.text(value, bundle: .module, arguments: arguments)
}
