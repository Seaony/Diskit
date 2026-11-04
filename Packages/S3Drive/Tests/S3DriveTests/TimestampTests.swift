import Foundation
import Testing

@testable import S3Drive

@Test(arguments: ["2026-01-02T03:04:05.123Z", "2026-01-02T03:04:05.123"])
func s3ObjectDatesPreserveMilliseconds(_ timestamp: String) throws {
  let xml =
    "<ListBucketResult><Contents><Key>demo</Key><Size>4</Size><LastModified>\(timestamp)</LastModified></Contents></ListBucketResult>"
  let result = try S3ListParser.parse(Data(xml.utf8))
  let item = try #require(result.objects.first)
  #expect(abs(item.modified.timeIntervalSince1970 - 1_767_323_045.123) < 0.00001)
}
