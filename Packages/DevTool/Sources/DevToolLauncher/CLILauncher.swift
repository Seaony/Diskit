import Darwin
import Foundation

enum CLILaunchError: Error, LocalizedError {
  case appNotFound, incompatibleApp, executionFailed(Int32)

  var errorDescription: String? {
    switch self {
    case .appNotFound:
      String(localized: "找不到支持命令行的 Kayoi.app，请先构建或安装新版 Kayoi。", bundle: .module)
    case .incompatibleApp:
      String(localized: "指定的 Kayoi.app 不支持命令行，请先构建或安装新版 Kayoi。", bundle: .module)
    case .executionFailed(let code):
      String(
        format: String(localized: "无法启动 Kayoi 命令行模式（errno %lld）。", bundle: .module),
        Int64(code))
    }
  }
}

enum CLIAppLocator {
  static func executable(
    launcher: URL, environment: [String: String],
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> URL {
    if let path = environment["KAYOI_APP_PATH"], !path.isEmpty {
      guard let executable = compatibleExecutable(in: URL(fileURLWithPath: path)) else {
        throw CLILaunchError.incompatibleApp
      }
      return executable
    }
    let build = launcher.resolvingSymlinksInPath().deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidates = [
      build.appending(path: "DerivedData/Build/Products/Debug/Kayoi.app"),
      build.appending(path: "DerivedData/Build/Products/Release/Kayoi.app"),
      URL(filePath: "/Applications/Kayoi.app"),
      home.appending(path: "Applications/Kayoi.app"),
    ]
    guard let executable = candidates.compactMap(compatibleExecutable).first else {
      throw CLILaunchError.appNotFound
    }
    return executable
  }

  private static func compatibleExecutable(in app: URL) -> URL? {
    let contents = app.appending(path: "Contents")
    guard let data = try? Data(contentsOf: contents.appending(path: "Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      info["CFBundleIdentifier"] as? String == "com.seaony.Kayoi",
      info["KayoiDevToolProtocolVersion"] as? Int == 1
    else { return nil }
    let executable = contents.appending(path: "MacOS/Kayoi")
    return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
  }
}

public enum CLILauncher {
  public static func run(_ arguments: [String]) throws {
    let launcher = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let executable = try CLIAppLocator.executable(
      launcher: launcher, environment: ProcessInfo.processInfo.environment)
    let strings = forwardedArguments(executable: executable, arguments: arguments).map { strdup($0) }
    defer { for string in strings { free(string) } }
    var pointers = strings + [nil]
    pointers.withUnsafeMutableBufferPointer { buffer in
      _ = execv(executable.path, buffer.baseAddress!)
    }
    throw CLILaunchError.executionFailed(errno)
  }

  static func forwardedArguments(executable: URL, arguments: [String]) -> [String] {
    [executable.path, "--dev-tool"] + arguments
  }
}
