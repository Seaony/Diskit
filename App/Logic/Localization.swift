import Core
import Foundation

func L(_ value: String) -> String { DiskitLocalization.text(value, bundle: .main) }
func LF(_ value: String, _ arguments: CVarArg...) -> String {
  DiskitLocalization.text(value, bundle: .main, arguments: arguments)
}
