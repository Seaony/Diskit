import Core
import Foundation

struct LanzouShareListing: Sendable {
  let page: LanzouSharePage
  let files: [LanzouEntry]
  let folders: [LanzouShareFolderLink]
}

public actor LanzouSession {
  private struct AccountContext: Sendable {
    let uid: String
    let vei: String
  }

  public nonisolated let configuration: LanzouConfiguration
  private let transport: any HTTPTransport
  private var accountCookie: LanzouCookieHeader?
  private var accountContext: AccountContext?
  private var shareCookies: LanzouCookieHeader?
  private var shareCookieOrigin: String?
  private var isConnected = false
  private var relativeDates: [String: (text: String, date: Date)] = [:]
  private let persistAccountCookie: (@Sendable (String) throws -> Void)?
  private var pendingAccountCookie: String?

  public init(
    configuration: LanzouConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    persistAccountCookie: (@Sendable (String) throws -> Void)? = nil
  ) {
    self.configuration = configuration
    self.transport = DiagnosticHTTPTransport(transport, category: .lanzouDrive)
    self.persistAccountCookie = persistAccountCookie
    accountCookie = configuration.accountCookie
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

  func accountChildren(folderID: String) async throws -> [LanzouEntry] {
    try requireConnection()
    let folderReply = try await accountRPC(
      ["task": "47", "folder_id": folderID])
    let folders = try LanzouJSON.array(folderReply["text"]).map {
      stabilize(
        try LanzouEntry.accountFolder($0), dateText: LanzouValues.string($0["time"]),
        scope: "account:" + folderID)
    }

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
      files.append(
        contentsOf: try records.map {
          stabilize(
            try LanzouEntry.accountFile($0), dateText: LanzouValues.string($0["time"]),
            scope: "account:" + folderID)
        })
    }
    pruneRelativeDates(scope: "account:" + folderID, keeping: folders + files)
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
            name: name, isDirectory: false, size: nil, modified: page.modified, id: "")
        ], folders: [])
    }

    guard var fields = page.fields.isEmpty ? nil : page.fields else {
      throw LanzouError.invalidResponse
    }
    if let password { fields["pwd"] = password }
    var files: [LanzouEntry] = []
    var seenPage = Set<String>()
    for number in 1... {
      try Task.checkCancellation()
      fields["pg"] = String(number)
      let endpoint = appendPath("filemoreajax.php", to: page.url)
      var request = URLRequest(url: endpoint, timeoutInterval: RemoteTimeout.cloudRequest)
      request.httpMethod = "POST"
      request.httpBody = Self.formBody(fields)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue("https://\(page.url.host ?? "")", forHTTPHeaderField: "Origin")
      request.setValue(page.url.absoluteString, forHTTPHeaderField: "Referer")
      request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
      let response = try await sendShare(request)
      try checkHTTP(response)
      let reply = try shareObject(response.body)
      let records = LanzouJSON.array(reply["text"])
      if records.isEmpty { break }
      let signature = records.compactMap { LanzouValues.string($0["id"]) }.joined(
        separator: "\u{1f}")
      guard !signature.isEmpty, seenPage.insert(signature).inserted else {
        throw LanzouError.invalidResponse
      }
      files.append(
        contentsOf: try records.map {
          stabilize(
            try LanzouEntry.shareFile($0), dateText: LanzouValues.string($0["time"]),
            scope: page.url.absoluteString)
        })
    }
    pruneRelativeDates(scope: page.url.absoluteString, keeping: files)
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
    let visible =
      pageHTML
      .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
      .replacingOccurrences(
        of: #"(?is)<script\b[^>]*>.*?</script>"#, with: "", options: .regularExpression)
    let frames = LanzouHTML.allMatches(
      #"(?is)<iframe\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#, in: visible)
    guard frames.count <= 1 else { throw LanzouError.invalidResponse }
    if let iframe = frames.first,
      let source = iframe[safe: 1] ?? nil,
      let innerURL = URL(string: source, relativeTo: page.url)?.absoluteURL,
      LanzouConfiguration.isHTTPSURL(innerURL)
    {
      if page.requiresPassword, Self.origin(innerURL) != Self.origin(page.url) {
        throw LanzouError.invalidResponse
      }
      let response = try await sendShare(
        URLRequest(url: innerURL, timeoutInterval: RemoteTimeout.cloudRequest))
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
    var request = URLRequest(url: endpoint, timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = "POST"
    request.httpBody = Self.formBody(fields)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("https://\(page.url.host ?? "")", forHTTPHeaderField: "Origin")
    request.setValue(page.url.absoluteString, forHTTPHeaderField: "Referer")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    let response = try await sendShare(request)
    try checkHTTP(response)
    let reply = try shareObject(response.body)
    return try Self.directDownloadURL(from: reply)
  }

  func streamDownload(
    _ url: URL, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try requireConnection()
    let request = try makeDownloadRequest(url, range: range)
    let stream = try await transport.stream(request)
    try checkHTTP(stream.response)
    let attachment = try Self.validateDownloadType(stream.response)
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

  private func makeDownloadRequest(_ url: URL, range: Range<Int64>?) throws -> URLRequest {
    guard LanzouConfiguration.isHTTPSURL(url) else { throw LanzouError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.transferIdle)
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

    return request
  }

  private static func validateDownloadType(_ response: HTTPResponse) throws -> Bool {
    let attachment =
      response.header("Content-Disposition")?
      .split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      == "attachment"
    let mediaType = response.header("Content-Type")?
      .split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !attachment, mediaType == "text/html" || mediaType == "application/xhtml+xml" {
      throw LanzouError.antiBotChallenge
    }
    if let encoding = response.header("Content-Encoding"),
      !encoding.isEmpty, encoding.lowercased() != "identity"
    {
      throw LanzouError.invalidResponse
    }
    return attachment
  }

  func downloadSize(_ url: URL) async throws -> Int64 {
    try requireConnection()
    var request = try makeDownloadRequest(url, range: nil)
    request.httpMethod = "HEAD"
    let response = try await transport.send(request)
    if response.status == 200 {
      _ = try Self.validateDownloadType(response)
      if let raw = response.header("Content-Length") {
        guard let length = Int64(raw), length >= 0 else { throw LanzouError.invalidResponse }
        return length
      }
    } else if response.status != 405 && response.status != 501 {
      try checkHTTP(response)
      throw LanzouError.invalidResponse
    }
    let stream = try await transport.stream(makeDownloadRequest(url, range: 0..<1))
    let ranged = stream.response
    if ranged.status == 416, ranged.header("Content-Range") == "bytes */0" { return 0 }
    try checkHTTP(ranged)
    _ = try Self.validateDownloadType(ranged)
    if ranged.status == 206 {
      guard Self.contentRangeLength(ranged.header("Content-Range"), for: 0..<1) == 1,
        let raw = ranged.header("Content-Range")?.split(separator: "/").last,
        let total = Int64(raw), total > 0,
        ranged.header("Content-Length") == nil || ranged.header("Content-Length") == "1"
      else { throw LanzouError.invalidResponse }
      return total
    }
    guard ranged.status == 200, let raw = ranged.header("Content-Length"),
      let length = Int64(raw), length >= 0
    else { throw LanzouError.invalidResponse }
    return length
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
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest)
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(configuration.shareBaseURL.absoluteString, forHTTPHeaderField: "Referer")
    let response = try await sendShare(request)
    try checkHTTP(response)
    guard let html = String(data: response.body, encoding: .utf8) else {
      throw LanzouError.invalidResponse
    }
    let resolved = response.url ?? url
    if password?.isEmpty == false, Self.origin(resolved) != Self.origin(url) {
      throw LanzouError.invalidResponse
    }
    var page = try LanzouSharePage.parse(html, url: resolved)
    page.modified = stableDate(
      page.modified, text: page.relativeDateText, identity: page.url.absoluteString)
    return page
  }

  private func stableDate(_ date: Date, text: String?, identity: String) -> Date {
    guard let text, LanzouValues.isRelativeDate(text) else {
      relativeDates.removeValue(forKey: identity)
      return date
    }
    if let previous = relativeDates[identity], previous.text == text { return previous.date }
    relativeDates[identity] = (text, date)
    return date
  }

  private func stabilize(_ entry: LanzouEntry, dateText: String?, scope: String) -> LanzouEntry {
    LanzouEntry(
      name: entry.name, isDirectory: entry.isDirectory, size: entry.size,
      modified: stableDate(
        entry.modified, text: dateText, identity: dateIdentity(entry, scope: scope)),
      id: entry.id)
  }

  private func dateIdentity(_ entry: LanzouEntry, scope: String) -> String {
    scope + "\u{0}" + (entry.isDirectory ? "folder:" : "file:") + entry.id
  }

  private func pruneRelativeDates(scope: String, keeping entries: [LanzouEntry]) {
    let keys = Set(entries.map { dateIdentity($0, scope: scope) })
    relativeDates = relativeDates.filter {
      !$0.key.hasPrefix(scope + "\u{0}") || keys.contains($0.key)
    }
  }

  private func downloadRequest(
    html: String, pageURL: URL, password: String?, requiresPassword: Bool
  ) throws -> (URL, [String: String]) {
    if html.contains("acw_sc__v2") { throw LanzouError.antiBotChallenge }
    let variables = LanzouHTML.variables(in: html)
    let endpointPatterns = ["/ajaxm.php", "/ajaxfile.php"]
    let parsed =
      LanzouScript.hasEndpoint(in: html, containing: endpointPatterns)
      ? try LanzouScript.request(in: html, endpointContains: endpointPatterns) : nil
    var fields = parsed?.fields ?? [:]
    if requiresPassword {
      guard let password, !password.isEmpty else { throw LanzouError.passwordRequired }
      fields["p"] = password
    }
    if let endpointText = parsed?.endpoint,
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
    let response = try await sendAccount(
      URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest))
    try checkHTTP(response, account: true)
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
    let variables = LanzouHTML.variables(in: html)
    let uid = variables["uid"]
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
    var request = URLRequest(url: url, timeoutInterval: RemoteTimeout.cloudRequest)
    request.httpMethod = "POST"
    request.httpBody = Self.formBody(fields)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let response = try await sendAccount(request)
    try checkHTTP(response, account: true)
    if String(data: response.body, encoding: .utf8)?.contains("acw_sc__v2") == true {
      throw LanzouError.antiBotChallenge
    }
    return try LanzouJSON.successfulObject(response.body)
  }

  private func sendAccount(_ request: URLRequest) async throws -> HTTPResponse {
    try persistPendingAccountCookie()
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
    guard Self.origin(response.url ?? destination) == Self.origin(configuration.accountBaseURL)
    else {
      throw LanzouError.invalidResponse
    }
    cookie = accountCookie ?? cookie
    let previous = cookie.text
    cookie.merge(response, from: destination)
    accountCookie = cookie
    if cookie.text != previous, persistAccountCookie != nil {
      pendingAccountCookie = cookie.text
      try persistPendingAccountCookie()
    }
    return response
  }

  private func persistPendingAccountCookie() throws {
    guard let pendingAccountCookie, let persistAccountCookie else { return }
    try persistAccountCookie(pendingAccountCookie)
    self.pendingAccountCookie = nil
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

  private func checkHTTP(_ response: HTTPResponse, account: Bool = false) throws {
    guard (200..<300).contains(response.status) else {
      if account, response.status == 401 || response.status == 403 {
        throw LanzouError.authenticationExpired
      }
      throw LanzouError.fromHTTP(response.status)
    }
  }

  private func shareObject(_ data: Data) throws -> [String: Any] {
    do { return try LanzouJSON.successfulObject(data) } catch LanzouError.authenticationExpired {
      throw LanzouError.http(401)
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
