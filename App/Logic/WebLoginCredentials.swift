import Foundation

struct WebLoginCredentials: Equatable, Sendable {
  var cookie: String? = nil
  var phone: String? = nil
  var token: String? = nil
  var userDomainID: String? = nil
}
