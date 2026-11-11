import Darwin
import Foundation
import Testing

@testable import DevToolLauncher

@Test func launcherErrorsIncludePackagedChineseAndEnglishTranslations() throws {
  let keys = [
    "找不到支持命令行的 Kayoi.app，请先构建或安装新版 Kayoi。",
    "指定的 Kayoi.app 不支持命令行，请先构建或安装新版 Kayoi。",
    "无法启动 Kayoi 命令行模式（errno %lld）。",
  ]
  for language in ["zh-Hans", "en"] {
    let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
    let bundle = try #require(Bundle(path: path))
    for key in keys {
      let value = bundle.localizedString(forKey: key, value: nil, table: nil)
      #expect(!value.isEmpty)
      #expect(language == "zh-Hans" ? value == key : value != key)
    }
    let format = bundle.localizedString(forKey: keys[2], value: nil, table: nil)
    #expect(String(format: format, Int64(13)).contains("errno 13"))
  }
  #expect(CLILaunchError.executionFailed(13).localizedDescription.contains("errno 13"))
}

private func launcherDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func writeApp(_ app: URL, version: Int? = 1, profile: Bool = true) throws -> URL {
  let contents = app.appending(path: "Contents")
  let executable = contents.appending(path: "MacOS/Kayoi")
  try FileManager.default.createDirectory(
    at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
  var info: [String: Any] = ["CFBundleIdentifier": "com.seaony.Kayoi"]
  info["KayoiDevToolProtocolVersion"] = version
  try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: contents.appending(path: "Info.plist"))
  if profile { try Data().write(to: contents.appending(path: "embedded.provisionprofile")) }
  try Data().write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return executable
}

@Test func launcherSelectsCompatibleDevelopmentAppAndPreservesArguments() throws {
  let root = try launcherDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let build = root.appending(path: "build")
  let debug = build.appending(path: "DerivedData/Build/Products/Debug/Kayoi.app")
  let release = build.appending(path: "DerivedData/Build/Products/Release/Kayoi.app")
  _ = try writeApp(debug, version: nil)
  let expected = try writeApp(release)
  let result = try CLIAppLocator.executable(
    launcher: build.appending(path: "bin/kayoi-dev"), environment: [:], home: root)
  #expect(result == expected)
  let arguments = ["put", "--", "connection", "a b'😀", "/-file"]
  #expect(CLILauncher.forwardedArguments(executable: result, arguments: arguments)
    == [expected.path, "--dev-tool"] + arguments)
  let preferred = try writeApp(debug)
  #expect(try CLIAppLocator.executable(
    launcher: build.appending(path: "bin/kayoi-dev"), environment: [:], home: root) == preferred)
}

@Test func launcherRejectsOldExplicitAppAndAcceptsCurrentAppWithoutProfile() throws {
  let root = try launcherDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = root.appending(path: "Kayoi.app")
  for version in [nil, 2] as [Int?] {
    if FileManager.default.fileExists(atPath: app.path) {
      try FileManager.default.removeItem(at: app)
    }
    _ = try writeApp(app, version: version)
    #expect(throws: CLILaunchError.self) {
      try CLIAppLocator.executable(
        launcher: root.appending(path: "kayoi-dev"), environment: ["KAYOI_APP_PATH": app.path],
        home: root)
    }
  }
  try FileManager.default.removeItem(at: app)
  let executable = try writeApp(app, profile: false)
  #expect(try CLIAppLocator.executable(
    launcher: root.appending(path: "kayoi-dev"), environment: ["KAYOI_APP_PATH": app.path],
    home: root) == executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
  #expect(throws: CLILaunchError.self) {
    try CLIAppLocator.executable(
      launcher: root.appending(path: "kayoi-dev"), environment: ["KAYOI_APP_PATH": app.path],
      home: root)
  }
}

@Test func launcherExecKeepsOutputExitStatusAndLiteralArguments() throws {
  let root = try launcherDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let app = root.appending(path: "Kayoi.app")
  let executable = try writeApp(app, profile: false)
  try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 23\n".utf8).write(to: executable)
  let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let process = Process()
  let output = Pipe()
  process.executableURL = package.appending(path: ".build/debug/kayoi-dev")
  process.arguments = ["cat", "--", "a b'😀", "$(must-stay-literal)"]
  process.environment = ["KAYOI_APP_PATH": app.path]
  process.standardOutput = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 23)
  #expect(String(decoding: data, as: UTF8.self)
    == "--dev-tool\ncat\n--\na b'😀\n$(must-stay-literal)\n")
}
