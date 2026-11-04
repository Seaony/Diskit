import Foundation

struct LanzouShareFolderLink: Equatable, Sendable {
  let url: URL
  let name: String
}

struct LanzouSharePage: Sendable {
  let url: URL
  let isFile: Bool
  let fileName: String?
  var modified: Date
  let relativeDateText: String?
  let requiresPassword: Bool
  let fields: [String: String]
  let folders: [LanzouShareFolderLink]
  let html: String

  static func parse(_ source: String, url: URL, relativeTo referenceDate: Date = Date()) throws
    -> LanzouSharePage
  {
    let html = source.replacingOccurrences(
      of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
    if html.contains("acw_sc__v2") { throw LanzouError.antiBotChallenge }
    if html.contains("取消分享") || html.contains("文件不存在") {
      throw LanzouError.notFound
    }

    let visible = html.replacingOccurrences(
      of: #"(?is)<script\b[^>]*>.*?</script>"#, with: "", options: .regularExpression)
    let lower = visible.lowercased()
    let passwordMarkers =
      lower.contains("pwdload") || lower.contains("passwddiv")
      || LanzouScript.containsIdentifier("pwdload", in: html)
    let fileMarkers =
      lower.contains("fileinfo") || lower.contains("id=\"file\"") || visible.contains("文件描述")
    let folderRequest = try? LanzouScript.request(in: html, endpointContains: ["filemoreajax.php"])
    let downloadRequest = try? LanzouScript.request(
      in: html, endpointContains: ["/ajaxm.php", "/ajaxfile.php"])
    let folderMarkers =
      LanzouHTML.firstMatch(#"id\s*=\s*["']infos["']"#, in: visible) != nil
      || lower.contains("folderlink") || lower.contains("mbxfolder")
      || folderRequest?.endpoint != nil
    let isFile = !folderMarkers && (fileMarkers || downloadRequest?.endpoint != nil)
    let fields = folderRequest?.fields ?? LanzouScript.fields(in: html)
    guard isFile || folderMarkers || !fields.isEmpty else {
      throw LanzouError.invalidResponse
    }
    let title = LanzouHTML.firstMatch(
      #"<title>\s*(.*?)\s*-\s*蓝奏云\s*</title>"#, in: html)?[1]
    let alternateName =
      LanzouScript.variables(in: html)["filename"]
      ?? LanzouHTML.firstMatch(#"id=["']filenajax["'][^>]*>(.*?)</div>"#, in: html).map {
        LanzouHTML.text($0[1] ?? "")
      }
    let fileName = [title, alternateName].compactMap { $0 }.first {
      !LanzouHTML.strippedText($0).isEmpty
    }.map(LanzouHTML.strippedText)
    if isFile, fileName?.isEmpty != false { throw LanzouError.invalidResponse }

    let rawDate = LanzouHTML.firstMatch(
      #"\d{4}[-/]\d{2}[-/]\d{2}(?:\s+\d{2}:\d{2}(?::\d{2})?)?|\d+\s*(?:秒|分钟?|小时?|天)前|昨天|前天"#,
      in: LanzouHTML.strippedText(visible))?[0]

    let folders = parseFolders(in: visible, baseURL: url)
    return LanzouSharePage(
      url: url, isFile: isFile, fileName: fileName,
      modified: LanzouValues.parseDate(rawDate, relativeTo: referenceDate),
      relativeDateText: LanzouValues.isRelativeDate(rawDate) ? rawDate : nil,
      requiresPassword: passwordMarkers,
      fields: fields, folders: folders, html: html)
  }

  private static func parseFolders(in html: String, baseURL: URL) -> [LanzouShareFolderLink] {
    let patterns = [
      #"(?is)<a\b([^>]*(?:folderlink|mbxfolder)[^>]*)>(.*?)</a>"#,
      #"(?is)<a\b([^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*)>(.*?)</a>"#,
    ]
    var output: [LanzouShareFolderLink] = []
    var seen = Set<String>()
    for (index, pattern) in patterns.enumerated() {
      for match in LanzouHTML.allMatches(pattern, in: html) {
        let attributes = (match[safe: 1] ?? nil) ?? ""
        let folderCandidate: Bool
        let href: String
        let inner: String
        if index == 0 {
          folderCandidate =
            attributes.lowercased().contains("folderlink")
            || attributes.lowercased().contains("mbxfolder")
          href =
            LanzouHTML.firstMatch(#"(?i)\bhref\s*=\s*["']([^"']+)["']"#, in: attributes)?[1]
            ?? ""
          inner = (match[safe: 2] ?? nil) ?? ""
        } else {
          folderCandidate =
            attributes.lowercased().contains("folderlink")
            || attributes.lowercased().contains("mbxfolder")
          href = (match[safe: 2] ?? nil) ?? ""
          inner = (match[safe: 3] ?? nil) ?? ""
        }
        guard folderCandidate, !href.isEmpty,
          let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
          url.scheme?.lowercased() == "https"
        else { continue }
        let name = LanzouHTML.strippedText(inner)
        guard !name.isEmpty, !name.contains("/"),
          seen.insert("\(url.absoluteString)\n\(name)").inserted
        else { continue }
        output.append(LanzouShareFolderLink(url: url, name: name))
      }
    }
    return output
  }
}
