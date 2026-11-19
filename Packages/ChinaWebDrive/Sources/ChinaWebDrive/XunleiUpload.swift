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
    do {
      try await performUpload(
        from: localFile, size: size, parameters: parameters, progress: progress)
    } catch {
      throw Self.map(error)
    }
  }

  private func performUpload(
    from localFile: URL, size: Int64, parameters: XunleiUploadParameters,
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
      .withTimeoutIntervalForRequest(RemoteTimeout.transferIdle)
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
      let deadline = HTTPProgressDeadline(interval: .seconds(RemoteTimeout.transferIdle))
      try await deadline.run {
        _ = try await client.putObject(
          PutObjectRequest(
            bucket: parameters.bucket, key: parameters.key, forbidOverwrite: true,
            body: .data(Data()),
            progress: ProgressClosure { increment, transferred, expected in
              if increment > 0 { deadline.recordProgress() }
              progress?(transferred, expected)
            }))
      }
      progress?(0, 0)
      return
    }

    let uploadID = try await HTTPProgressDeadline(interval: .seconds(RemoteTimeout.cloudRequest))
      .run {
        try await client.initiateMultipartUpload(
          InitiateMultipartUploadRequest(
            bucket: parameters.bucket, key: parameters.key, forbidOverwrite: true)
        ).uploadId
      }
    guard let uploadID, !uploadID.isEmpty else {
      throw RemoteError.protocolError
    }
    do {
      var uploaded: [UploadPart] = []
      for part in parts {
        try Task.checkCancellation()
        let partFile = try XunleiPartFile(
          source: localFile, offset: part.offset, length: part.length)
        let deadline = HTTPProgressDeadline(interval: .seconds(RemoteTimeout.transferIdle))
        let etag = try await deadline.run {
          try await client.uploadPart(
            UploadPartRequest(
              bucket: parameters.bucket, key: parameters.key, partNumber: part.number,
              uploadId: uploadID, body: .file(partFile.url),
              progress: ProgressClosure { increment, transferred, _ in
                if increment > 0 { deadline.recordProgress() }
                progress?(part.offset + transferred, size)
              })
          ).etag
        }
        withExtendedLifetime(partFile) {}
        guard let etag, !etag.isEmpty else { throw RemoteError.protocolError }
        uploaded.append(UploadPart(etag: etag, partNumber: part.number))
        progress?(part.offset + part.length, size)
      }
      let completionParts = uploaded
      let completed = try await HTTPProgressDeadline(interval: .seconds(RemoteTimeout.cloudRequest))
        .run {
          let result = try await client.completeMultipartUpload(
            CompleteMultipartUploadRequest(
              bucket: parameters.bucket, key: parameters.key, forbidOverwrite: true,
              uploadId: uploadID,
              completeMultipartUpload: CompleteMultipartUpload(parts: completionParts)))
          return (key: result.key, etag: result.etag)
        }
      guard completed.key == nil || completed.key == parameters.key,
        let etag = completed.etag, !etag.isEmpty
      else { throw RemoteError.protocolError }
    } catch {
      let client = client
      let parameters = parameters
      let uploadID = uploadID
      let cleanup = Task.detached {
        try? await HTTPProgressDeadline(interval: .seconds(RemoteTimeout.cloudRequest)).run {
          _ = try await client.abortMultipartUpload(
            AbortMultipartUploadRequest(
              bucket: parameters.bucket, key: parameters.key, uploadId: uploadID))
        }
      }
      await cleanup.value
      throw Self.map(error)
    }
  }

  static func map(_ error: Error) -> Error {
    if error is CancellationError || error is RemoteError || error is XunleiError {
      return error
    }
    if let wrapped = error as? ClientError, let inner = wrapped.innerError {
      return map(inner)
    }
    if let fileError = error as? CocoaError {
      switch fileError.code {
      case .fileWriteOutOfSpace: return RemoteError.posix(ENOSPC)
      case .fileNoSuchFile, .fileReadNoSuchFile: return RemoteError.posix(ENOENT)
      case .fileReadNoPermission, .fileWriteNoPermission: return RemoteError.posix(EACCES)
      default: break
      }
    }
    if let error = error as? ServerError {
      switch error.statusCode {
      case 401, 403: return RemoteError.posix(EACCES)
      case 404: return RemoteError.posix(ENOENT)
      case 408, 504: return RemoteError.posix(ETIMEDOUT)
      case 409, 412: return RemoteError.posix(EEXIST)
      case 413: return RemoteError.tooLarge
      case 429, 503: return RemoteError.rateLimited
      case 507: return RemoteError.posix(ENOSPC)
      case 400, 416: return RemoteError.posix(EINVAL)
      default:
        // 其他状态把对象存储的原话和错误码写出来，方便排查
        return RemoteError.failed(
          EIO,
          LF(
            "迅雷上传服务返回错误：%@（错误码 %@，HTTP %@）",
            error.message.isEmpty ? L("没有说明") : error.message, error.code,
            String(error.statusCode)))
      }
    }
    // 不是网络错误就报出它自己的说明，不压成笼统的读写错误
    if !NetworkFailure.isTransportError(error), (error as NSError).domain != NSPOSIXErrorDomain {
      // SDK 错误的完整描述里有类型和字段（比如 CRC64 校验不一致时两端的值），一起带上
      let text = error.localizedDescription
      let full = String(describing: error)
      return RemoteError.failed(
        EIO, LF("迅雷上传失败：%@", full == text || full.isEmpty ? text : text + "（" + full + "）"))
    }
    return NetworkFailure.posix(error)
  }
}
