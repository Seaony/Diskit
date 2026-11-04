import Foundation

// 只读取和替换认证字段，保留上传正文及其他参数的原始编码。
enum OAuthRequestToken {
  static func read(from request: URLRequest) -> String? {
    if let authorization = request.value(forHTTPHeaderField: "Authorization"),
      authorization.hasPrefix("Bearer ")
    {
      return String(authorization.dropFirst(7))
    }
    if let url = request.url,
      let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "access_token" })?.value
    {
      return token
    }
    guard isForm(request), let body = request.httpBody,
      let form = String(data: body, encoding: .utf8)
    else { return nil }
    return form.split(separator: "&").compactMap { field -> String? in
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard decode(String(pair[0])) == "access_token", pair.count == 2 else { return nil }
      return decode(String(pair[1]))
    }.first
  }

  static func replacing(in request: URLRequest, with token: String) -> URLRequest {
    var retry = request
    if request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true {
      retry.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let url = request.url,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let query = components.percentEncodedQuery
    {
      components.percentEncodedQuery = replacingField(in: query, with: token)
      retry.url = components.url
    }
    if isForm(request), let body = request.httpBody,
      let form = String(data: body, encoding: .utf8)
    {
      retry.httpBody = Data(replacingField(in: form, with: token).utf8)
    }
    return retry
  }

  private static func isForm(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "Content-Type")?
      .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
      == "application/x-www-form-urlencoded"
  }

  private static func decode(_ value: String) -> String? {
    value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
  }

  private static func replacingField(in value: String, with token: String) -> String {
    value.split(separator: "&", omittingEmptySubsequences: false).map { field in
      let key =
        field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
      guard decode(String(key)) == "access_token" else { return String(field) }
      return "\(key)=\(CloudDriveSupport.encode(token))"
    }.joined(separator: "&")
  }
}
