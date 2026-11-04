import Core
import Foundation

struct LanzouShareListing: Sendable {
  let page: LanzouSharePage
  let files: [LanzouEntry]
  let folders: [LanzouShareFolderLink]
}

actor LanzouSession {
  private struct AccountContext: Sendable {
    let uid: String
    let vei: String
  }

  private let configuration: LanzouConfiguration
  private let transport: any HTTPTransport
  private var accountCookie: LanzouCookieHeader?
  private var accountContext: AccountContext?
  private var shareCookies: LanzouCookieHeader?
  private var shareCookieOrigin: String?
  private var isConnected = false

  init(
    configuration: LanzouConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.configuration = configuration
    self.transport = transport
    switch configuration.authentication {
    case .accountCookie(let value):
      accountCookie = try? LanzouCookieHeader(value)
    case .share:
      accountCookie = nil
    }
  }

  func connect() async throws {
    switch configuration.authentication {
    case .accountCookie:
      accountContext = try await loadAccountContext()
    case .share(let url, let password):
      let page = try await loadSharePage(url, password: password)
      if page.requiresPassword, password?.isEmpty != false {
        throw LanzouError.passwordRequired
      }
    }
    isConnected = true
  }

  func disconnect() {
    isConnected = false
    accountContext = nil
    shareCookies = nil
    shareCookieOrigin = nil
  }

  func accountChildren(folderID: String) async throws -> [LanzouEntry] {
    try requireConnection()
    let folderReply = try await accountRPC(
      ["task": "47", "folder_id": folderID])
    let folders = try LanzouJSON.array(folderReply["text"]).map(LanzouEntry.accountFolder)

    var files: [LanzouEntry] = []
    var seenPage = Set<String>()
    for page in 1... {
      try Task.checkCancellation()
      let reply = try await accountRPC(
        ["task": "5", "folder_id": folderID, "pg": String(page)])
      let records = LanzouJSON.array(reply["text"])
      if records.isEmpty { break }
      let signature = records.compactMap {
        LanzouValues.string($0["id"]) ?? LanzouValues.string($0["name_all"])
      }.joined(separator: "\u{1f}")
      guard seenPage.insert(signature).inserted else { throw LanzouError.invalidResponse }
      files.append(contentsOf: try records.map(LanzouEntry.accountFile))
    }
    return folders + files
  }

  func shareListing(url: URL, password: String?) async throws -> LanzouShareListing {
    try requireConnection()
    let page = try await loadSharePage(url, password: password)
    if page.isFile {
      let name = page.fileName ?? ""
      return LanzouShareListing(
        page: page,
        files: [
          LanzouEntry(
            name: name, isDirectory: false, size: page.size, modified: page.modified, id: "")
        ], folders: [])
    }

    guard var fields = page.fields.isEmpty ? nil : page.fields else {
      throw LanzouError.invalidResponse
    }
    if let password { fields["p"] = password }
    var files: [LanzouEntry] = []
    var seenPage = Set<String>()
    for number in 1... {
      try Task.checkCancellation()
      fields["pg"] = String(number)
      let endpoint = appendPath("filemoreajax.php", to: page.url)
      var request = URLRequest(url: endpoint, timeoutInterval: 30)
      request.httpMethod = "POST"
      request.httpBody = Self.formBody(fields)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue("https://\(page.url.host ?? "")", forHTTPHeaderField: "Origin")
      request.setValue(page.url.absoluteString, forHTTPHeaderField: "Referer")
      request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
      let response = try await sendShare(request)
      try checkHTTP(response)
      let reply = try LanzouJSON.successfulObject(response.body)
      let records = LanzouJSON.array(reply["text"])
      if records.isEmpty { break }
      let signature = records.compactMap { LanzouValues.string($0["id"]) }.joined(
        separator: "\u{1f}")
      guard !signature.isEmpty, seenPage.insert(signature).inserted else {
        throw LanzouError.invalidResponse
      }
      files.append(contentsOf: try records.map(LanzouEntry.shareFile))
    }
    return LanzouShareListing(page: page, files: files, folders: page.folders)
  }

  func accountDownloadLocation(fileID: String) async throws -> (URL, String?) {
    try requireConnection()
    let reply = try await accountRPC(["task": "22", "file_id": fileID])
    guard let info = reply["info"] as? [String: Any],
      let shareID = LanzouValues.string(info["f_id"]), !shareID.isEmpty
    else { throw LanzouError.invalidResponse }
    let newURL = LanzouValues.string(info["new_url"])
    let url: URL
    if let newURL, let value = URL(string: newURL, relativeTo: configuration.shareBaseURL),
      LanzouConfiguration.isHTTPSURL(value.absoluteURL)
    {
      url = value.absoluteURL
    } else {
      guard
        let value = URL(
          string: shareID, relativeTo: configuration.shareBaseURL.appendingPathComponent("/"))
      else { throw LanzouError.invalidResponse }
      url = value.absoluteURL
    }
    return (url, LanzouValues.string(info["pwd"]))
  }

  func shareDownloadURL(url: URL, password: String?) async throws -> URL {
    try requireConnection()
    let page = try await loadSharePage(url, password: password)
    guard page.isFile else { throw RemoteError.posix(EISDIR) }
    if page.requiresPassword, password?.isEmpty != false {
      throw LanzouError.passwordRequired
    }

    var pageHTML = page.html
    var pageURL = page.url
    if let iframe = LanzouHTML.firstMatch(
      #"(?is)<iframe\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#, in: pageHTML),
      let source = iframe[1],
      let innerURL = URL(string: source, relativeTo: page.url)?.absoluteURL,
      LanzouConfiguration.isHTTPSURL(innerURL)
    {
      let response = try await sendShare(URLRequest(url: innerURL, timeoutInterval: 30))
      try checkHTTP(response)
      guard let html = String(data: response.body, encoding: .utf8) else {
        throw LanzouError.invalidResponse
      }
      if html.contains("acw_sc__v2") { throw LanzouError.antiBotChallenge }
      pageHTML = html
      pageURL = response.url ?? innerURL
    }

    let (endpoint, fields) = try downloadRequest(
      html: pageHTML, pageURL: pageURL, password: password, requiresPassword: page.requiresPassword)
    var request = URLRequest(url: endpoint, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.httpBody = Self.formBody(fields)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("https://\(page.url.host ?? "")", forHTTPHeaderField: "Origin")
    request.setValue(page.url.absoluteString, forHTTPHeaderField: "Referer")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    let response = try await sendShare(request)
    try checkHTTP(response)
    let reply = try LanzouJSON.successfulObject(response.body)
    return try Self.directDownloadURL(from: reply)
  }

  func streamDownload(
    _ url: URL, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try requireConnection()
    guard LanzouConfiguration.isHTTPSURL(url) else { throw LanzouError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://\(url.host ?? "")/file/", forHTTPHeaderField: "Referer")
    if let range {
      request.setValue(
        "bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }
    var cookie = try LanzouCookieHeader("down_ip=1")
    if shareCookieOrigin == Self.origin(url), let shareCookies {
      for pair in shareCookies.text.split(separator: ";") {
        let values = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if values.count == 2 {
          cookie.add(
            String(values[0]), value: String(values[1]).trimmingCharacters(in: .whitespaces))
        }
      }
    }
    request.setValue(cookie.text, forHTTPHeaderField: "Cookie")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

    let stream = try await transport.stream(request)
    try checkHTTP(stream.response)
    let attachment =
      stream.response.header("Content-Disposition")?
      .split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      == "attachment"
    let mediaType = stream.response.header("Content-Type")?
      .split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !attachment, mediaType == "text/html" || mediaType == "application/xhtml+xml" {
      throw LanzouError.antiBotChallenge
    }
    let declaredLength: Int64?
    if let header = stream.response.header("Content-Length") {
      guard let length = Int64(header), length >= 0 else { throw LanzouError.invalidResponse }
      declaredLength = length
    } else {
      declaredLength = nil
    }
    let expectedLength: Int64?
    if let range {
      if stream.response.status == 200 { throw LanzouError.rangeUnsupported }
      guard stream.response.status == 206,
        let length = Self.contentRangeLength(stream.response.header("Content-Range"), for: range),
        declaredLength == nil || declaredLength == length
      else { throw LanzouError.invalidResponse }
      expectedLength = length
    } else {
      guard stream.response.status == 200 else { throw LanzouError.invalidResponse }
      expectedLength = declaredLength
    }
    let cursor = LanzouDownloadBody(
      stream.body, expectedLength: expectedLength,
      inspectHTML: !attachment && (range == nil || range?.lowerBound == 0))
    return AsyncThrowingStream(unfolding: { try await cursor.next() })
  }

  static func contentRangeLength(_ header: String?, for range: Range<Int64>) -> Int64? {
    guard range.lowerBound >= 0, !range.isEmpty,
      let header, header.lowercased().hasPrefix("bytes ")
    else { return nil }
    let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let limits = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    guard limits.count == 2, let start = Int64(limits[0]), let end = Int64(limits[1]),
      start == range.lowerBound, end >= start, end < range.upperBound
    else { return nil }
    if parts[1] == "*" {
      guard end == range.upperBound - 1 else { return nil }
    } else {
      guard let total = Int64(parts[1]), total > end,
        end == min(range.upperBound, total) - 1
      else { return nil }
    }
    return end - start + 1
  }

  private func loadSharePage(_ url: URL, password: String?) async throws -> LanzouSharePage {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(configuration.shareBaseURL.absoluteString, forHTTPHeaderField: "Referer")
    let response = try await sendShare(request)
    try checkHTTP(response)
    guard let html = String(data: response.body, encoding: .utf8) else {
      throw LanzouError.invalidResponse
    }
    return try LanzouSharePage.parse(html, url: response.url ?? url)
  }

  private func downloadRequest(
    html: String, pageURL: URL, password: String?, requiresPassword: Bool
  ) throws -> (URL, [String: String]) {
    if html.contains("acw_sc__v2") { throw LanzouError.antiBotChallenge }
    let variables = LanzouHTML.variables(in: html)
    var fields = LanzouHTML.keyValueObject(in: html, variables: variables)
    if requiresPassword {
      guard let password, !password.isEmpty else { throw LanzouError.passwordRequired }
      fields["p"] = password
    }
    if let endpointText = LanzouHTML.firstMatch(
      #"(?i)((?:https?://[^'"\s]+)?/ajax(?:m|file)\.php\?file=\d+\b)"#, in: html)?[1],
      let endpoint = URL(string: endpointText, relativeTo: pageURL)?.absoluteURL,
      LanzouConfiguration.isHTTPSURL(endpoint)
    {
      if requiresPassword, Self.origin(endpoint) != Self.origin(pageURL) {
        throw LanzouError.invalidResponse
      }
      return (endpoint, fields)
    }

    let endpointText = ["domain1", "domain2"].compactMap { variables[$0] }.first {
      $0.contains("ajaxfile.php")
    }
    guard let endpointText,
      let endpoint = URL(string: endpointText, relativeTo: pageURL)?.absoluteURL,
      LanzouConfiguration.isHTTPSURL(endpoint),
      let websignKey = variables["ajaxdata"], let sign = variables["wp_sign"]
    else { throw LanzouError.invalidResponse }
    if requiresPassword, Self.origin(endpoint) != Self.origin(pageURL) {
      throw LanzouError.invalidResponse
    }
    fields.merge(
      [
        "action": "downprocess", "websignkey": websignKey, "signs": websignKey,
        "sign": sign, "websign": "2", "kd": "1", "ves": "1",
      ], uniquingKeysWith: { _, new in new })
    return (endpoint, fields)
  }

  private static func directDownloadURL(from reply: [String: Any]) throws -> URL {
    if let text = LanzouValues.string(reply["url"]),
      let absolute = URL(string: text), LanzouConfiguration.isHTTPSURL(absolute)
    {
      return absolute
    }
    guard let domain = LanzouValues.string(reply["dom"]),
      let relative = LanzouValues.string(reply["url"]), !relative.isEmpty
    else { throw LanzouError.invalidResponse }
    let base =
      domain.hasPrefix("//")
      ? "https:" + domain
      : domain.contains("://") ? domain : "https://" + domain
    let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(trimmed)/file/\(relative)"),
      LanzouConfiguration.isHTTPSURL(url)
    else { throw LanzouError.invalidResponse }
    return url
  }

  private func loadAccountContext() async throws -> AccountContext {
    guard
      var components = URLComponents(
        url: appendPath("mydisk.php", to: configuration.accountBaseURL),
        resolvingAgainstBaseURL: false)
    else { throw LanzouError.invalidConfiguration }
    components.queryItems = [
      URLQueryItem(name: "item", value: "files"), URLQueryItem(name: "action", value: "index"),
    ]
    guard let url = components.url else { throw LanzouError.invalidConfiguration }
    let response = try await sendAccount(URLRequest(url: url, timeoutInterval: 30))
    try checkHTTP(response)
    guard let html = String(data: response.body, encoding: .utf8) else {
      throw LanzouError.invalidResponse
    }
    if html.contains("acw_sc__v2") { throw LanzouError.antiBotChallenge }
    let path = (response.url ?? url).path.lowercased()
    let lowerHTML = html.lowercased()
    if path.contains("login") || path.contains("mlogin")
      || lowerHTML.contains("mlogin.php") || lowerHTML.contains("请先登录")
      || lowerHTML.contains("name=\"pwd\"")
    {
      throw LanzouError.authenticationExpired
    }
    let uid = LanzouHTML.firstMatch(
      #"(?i)\buid\s*=\s*['"]?([^'"&;\s]+)"#, in: html)?[1]
    let variables = LanzouHTML.variables(in: html)
    let vei = variables["vei"] ?? LanzouHTML.keyValueObject(in: html, variables: variables)["vei"]
    guard let uid, !uid.isEmpty, let vei, !vei.isEmpty else {
      throw LanzouError.invalidResponse
    }
    return AccountContext(uid: uid, vei: vei)
  }

  private func accountRPC(_ fields: [String: String]) async throws -> [String: Any] {
    guard let context = accountContext else { throw LanzouError.authenticationRequired }
    guard
      var components = URLComponents(
        url: appendPath("doupload.php", to: configuration.accountBaseURL),
        resolvingAgainstBaseURL: false)
    else { throw LanzouError.invalidResponse }
    components.queryItems = [
      URLQueryItem(name: "uid", value: context.uid),
      URLQueryItem(name: "vei", value: context.vei),
    ]
    guard let url = components.url else { throw LanzouError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.httpBody = Self.formBody(fields)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let response = try await sendAccount(request)
    try checkHTTP(response)
    if String(data: response.body, encoding: .utf8)?.contains("acw_sc__v2") == true {
      throw LanzouError.antiBotChallenge
    }
    return try LanzouJSON.successfulObject(response.body)
  }

  private func sendAccount(_ request: URLRequest) async throws -> HTTPResponse {
    guard let destination = request.url,
      Self.origin(destination) == Self.origin(configuration.accountBaseURL),
      var cookie = accountCookie
    else { throw LanzouError.invalidConfiguration }
    var request = request
    request.setValue(cookie.text, forHTTPHeaderField: "Cookie")
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(configuration.accountBaseURL.absoluteString, forHTTPHeaderField: "Referer")
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    let response = try await transport.send(request)
    cookie.merge(response, from: destination)
    accountCookie = cookie
    return response
  }

  private func sendShare(_ request: URLRequest) async throws -> HTTPResponse {
    guard let destination = request.url, LanzouConfiguration.isHTTPSURL(destination) else {
      throw LanzouError.invalidConfiguration
    }
    var request = request
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    var cookie = try LanzouCookieHeader("")
    if shareCookieOrigin == Self.origin(destination), let shareCookies {
      cookie = shareCookies
    }
    if !cookie.text.isEmpty {
      request.setValue(cookie.text, forHTTPHeaderField: "Cookie")
    }
    let response = try await transport.send(request)
    let responseURL = response.url ?? destination
    guard LanzouConfiguration.isHTTPSURL(responseURL) else {
      throw LanzouError.invalidResponse
    }
    if shareCookieOrigin == Self.origin(responseURL) || shareCookieOrigin == nil {
      cookie.merge(response, from: destination)
      shareCookies = cookie
      shareCookieOrigin = Self.origin(responseURL)
    }
    return response
  }

  private func checkHTTP(_ response: HTTPResponse) throws {
    guard (200..<300).contains(response.status) else {
      throw LanzouError.fromHTTP(response.status)
    }
  }

  private func appendPath(_ path: String, to base: URL) -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      return base
    }
    components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.query = nil
    components.fragment = nil
    return components.url ?? base
  }

  private func requireConnection() throws {
    guard isConnected else { throw RemoteError.notConnected }
  }

  private static func formBody(_ values: [String: String]) -> Data {
    let allowed = CharacterSet(
      charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*")
    return Data(
      values.keys.sorted().map { key in
        let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let value = (values[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return name + "=" + value
      }.joined(separator: "&").utf8)
  }

  private static func origin(_ url: URL) -> String {
    let scheme = url.scheme?.lowercased() ?? ""
    let host = url.host?.lowercased() ?? ""
    let port = url.port.map { ":\($0)" } ?? ""
    return scheme + "://" + host + port
  }
}
