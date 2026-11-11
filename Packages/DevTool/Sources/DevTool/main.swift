import DevToolLauncher
import Foundation

do { try CLILauncher.run(Array(CommandLine.arguments.dropFirst())) } catch {
  try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
  exit(1)
}
