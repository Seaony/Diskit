import AlibabaCloudOSS
import Core
import Foundation

struct XunleiUploadParameters: Equatable, Sendable {
  let endpoint: URL
  let region: String?
  let accessKeyID: String
  let accessKeySecret: String
  let bucket: String
  let securityToken: String?
  let key: String
  let partSize: Int64
}

protocol XunleiVendorUploader: Sendable {
  func upload(
    from localFile: URL,
    size: Int64,
    parameters: XunleiUploadParameters,
    progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws
}

struct XunleiUploadPart: Equatable, Sendable {
  let number: Int
  let offset: Int64
  let length: Int64

  static func split(size: Int64, requestedPartSize: Int64) throws -> [Self] {
    guard size >= 0, requestedPartSize >= 100 * 1024,
      requestedPartSize <= 5 * 1024 * 1024 * 1024
    else { throw RemoteError.posix(EINVAL) }
    if size == 0 { return [] }
    let needed = size / 10_000 + (size % 10_000 == 0 ? 0 : 1)
    let partSize = max(requestedPartSize, needed)
    guard partSize <= 5 * 1024 * 1024 * 1024 else {
      throw RemoteError.posix(EFBIG)
    }
    var parts: [Self] = []
    var offset: Int64 = 0
    while offset < size {
      let length = min(partSize, size - offset)
      parts.append(Self(number: parts.count + 1, offset: offset, length: length))
      offset += length
    }
    return parts
  }
}

struct AliyunOSSXunleiUploader: XunleiVendorUploader {
  func upload(
    from localFile: URL,
    size: Int64,
    parameters: XunleiUploadParameters,
    progress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws {
    let configuration = Configuration.default()
      .withEndpoint(parameters.endpoint.absoluteString)
      .withCredentialsProvider(
        StaticCredentialsProvider(
          accessKeyId: parameters.accessKeyID,
          accessKeySecret: parameters.accessKeySecret,
          securityToken: parameters.securityToken
        )
      )
      .withSignerVersion(.v1)
      .withRetryMaxAttempts(3)
      .withTimeoutIntervalForRequest(60)
      .withUploadCRC64Validation(true)
    if let region = parameters.region, !region.isEmpty {
      configuration.withRegion(region)
    }
    if let host = parameters.endpoint.host?.lowercased() {
      configuration.withUseCname(host.hasPrefix(parameters.bucket.lowercased() + "."))
    }
    let client = Client(configuration)
    let parts = try XunleiUploadPart.split(
      size: size, requestedPartSize: parameters.partSize)
    guard !parts.isEmpty else {
      _ = try await client.putObject(
        PutObjectRequest(
          bucket: parameters.bucket,
          key: parameters.key,
          forbidOverwrite: true,
          body: .data(Data()),
          progress: ProgressClosure { _, transferred, expected in
            progress?(transferred, expected)
          }
        )
      )
      progress?(0, 0)
      return
    }

    let initiated = try await client.initiateMultipartUpload(
      InitiateMultipartUploadRequest(
        bucket: parameters.bucket,
        key: parameters.key,
        forbidOverwrite: true
      )
    )
    guard let uploadID = initiated.uploadId, !uploadID.isEmpty else {
      throw RemoteError.protocolError
    }
    do {
      let handle = try FileHandle(forReadingFrom: localFile)
      defer { try? handle.close() }
      var uploaded: [UploadPart] = []
      for part in parts {
        try Task.checkCancellation()
        try handle.seek(toOffset: UInt64(part.offset))
        var body = Data()
        while body.count < Int(part.length) {
          guard let chunk = try handle.read(upToCount: Int(part.length) - body.count),
            !chunk.isEmpty
          else { throw RemoteError.posix(EIO) }
          body.append(chunk)
        }
        let result = try await client.uploadPart(
          UploadPartRequest(
            bucket: parameters.bucket,
            key: parameters.key,
            partNumber: part.number,
            uploadId: uploadID,
            body: .data(body),
            progress: ProgressClosure { _, transferred, expected in
              progress?(part.offset + transferred, expected)
            }
          )
        )
        guard let etag = result.etag, !etag.isEmpty else {
          throw RemoteError.protocolError
        }
        uploaded.append(UploadPart(etag: etag, partNumber: part.number))
        progress?(part.offset + part.length, size)
      }
      let completed = try await client.completeMultipartUpload(
        CompleteMultipartUploadRequest(
          bucket: parameters.bucket,
          key: parameters.key,
          forbidOverwrite: true,
          uploadId: uploadID,
          completeMultipartUpload: CompleteMultipartUpload(parts: uploaded)
        )
      )
      guard completed.key == nil || completed.key == parameters.key,
        let etag = completed.etag, !etag.isEmpty
      else { throw RemoteError.protocolError }
    } catch {
      let client = client
      let parameters = parameters
      let uploadID = uploadID
      let cleanup = Task.detached {
        _ = try? await client.abortMultipartUpload(
          AbortMultipartUploadRequest(
            bucket: parameters.bucket,
            key: parameters.key,
            uploadId: uploadID
          )
        )
      }
      await cleanup.value
      throw Self.map(error)
    }
  }

  private static func map(_ error: Error) -> Error {
    if error is CancellationError || error is RemoteError || error is XunleiError {
      return error
    }
    if let error = error as? ServerError {
      switch error.statusCode {
      case 401, 403: return RemoteError.posix(EACCES)
      case 409, 412: return RemoteError.posix(EEXIST)
      case 413: return RemoteError.tooLarge
      case 429, 503: return RemoteError.rateLimited
      case 507: return RemoteError.posix(ENOSPC)
      case 400, 416: return RemoteError.posix(EINVAL)
      default: return RemoteError.posix(EIO)
      }
    }
    return RemoteError.posix(EIO)
  }
}
