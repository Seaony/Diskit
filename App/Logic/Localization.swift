import Core
import Foundation

func L(_ value: String) -> String { KayoiLocalization.text(value, bundle: .main) }
func LF(_ value: String, _ arguments: CVarArg...) -> String {
  KayoiLocalization.text(value, bundle: .main, arguments: arguments)
}
