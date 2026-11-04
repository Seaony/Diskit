import Core
import Foundation

struct S3ListObject: Sendable {
  let key: String
  let size: Int64
  let modified: Date
}

struct S3ListPage: Sendable {
  let objects: [S3ListObject]
  let prefixes: [String]
  let nextToken: String?
  let isTruncated: Bool
}

final class S3ListParser: NSObject, XMLParserDelegate {
  private var objects: [S3ListObject] = []
  private var prefixes: [String] = []
  private var nextToken: String?
  private var isTruncated = false
  private var stack: [String] = []
  private var text = ""
  private var objectKey = ""
  private var objectSize: Int64 = 0
  private var objectDate = Date(timeIntervalSince1970: 0)

  static func parse(_ data: Data) throws -> S3ListPage {
    let delegate = S3ListParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { throw RemoteErrorParser.invalid }
    return S3ListPage(
      objects: delegate.objects, prefixes: delegate.prefixes, nextToken: delegate.nextToken,
      isTruncated: delegate.isTruncated)
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String] = [:]
  ) {
    stack.append(elementName)
    text = ""
    if elementName == "Contents" {
      objectKey = ""
      objectSize = 0
      objectDate = Date(timeIntervalSince1970: 0)
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "Key" where stack.dropLast().last == "Contents": objectKey = value
    case "Size" where stack.dropLast().last == "Contents": objectSize = Int64(value) ?? -1
    case "LastModified" where stack.dropLast().last == "Contents":
      objectDate =
        RemoteTimestamp.parse(value)
        ?? Date(timeIntervalSince1970: 0)
    case "Prefix" where stack.dropLast().last == "CommonPrefixes": prefixes.append(value)
    case "NextContinuationToken": nextToken = value.isEmpty ? nil : value
    case "IsTruncated": isTruncated = value.lowercased() == "true"
    case "Contents":
      if !objectKey.isEmpty, objectSize >= 0 {
        objects.append(S3ListObject(key: objectKey, size: objectSize, modified: objectDate))
      }
    default: break
    }
    _ = stack.popLast()
    text = ""
  }
}

enum S3MultipartParser {
  static func value(named name: String, in data: Data) -> String? {
    let parser = XMLParser(data: data)
    let delegate = SingleValueDelegate(target: name)
    parser.delegate = delegate
    _ = parser.parse()
    return delegate.value
  }

  static func complete(etags: [(Int, String)]) -> Data {
    func escape(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    }
    let parts = etags.map {
      "<Part><PartNumber>\($0.0)</PartNumber><ETag>\(escape($0.1))</ETag></Part>"
    }.joined()
    return Data(
      ("<CompleteMultipartUpload>" + parts + "</CompleteMultipartUpload>").utf8)
  }
}

struct S3ErrorPayload: Equatable, Sendable {
  let code: String
  let message: String?
}

enum S3ErrorParser {
  static func parse(_ data: Data) -> S3ErrorPayload? {
    guard !data.isEmpty else { return nil }
    let parser = XMLParser(data: data)
    let delegate = S3ErrorDelegate()
    parser.delegate = delegate
    guard parser.parse(), let code = delegate.code, !code.isEmpty else { return nil }
    return S3ErrorPayload(code: code, message: delegate.message)
  }
}

private final class SingleValueDelegate: NSObject, XMLParserDelegate {
  let target: String
  var value: String?
  private var text = ""
  init(target: String) { self.target = target }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == target {
      value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
}

private final class S3ErrorDelegate: NSObject, XMLParserDelegate {
  var code: String?
  var message: String?
  private var text = ""

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if elementName == "Code" { code = value }
    if elementName == "Message" { message = value }
    text = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
}

enum RemoteErrorParser: Error {
  case invalid
}
