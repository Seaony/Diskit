import DevToolSupport
import Foundation

do { try await CLIRunner.run(Array(CommandLine.arguments.dropFirst())) } catch {
  try? FileHandle.standardError.write(contentsOf: Data((CLIOutput.errorMessage(error) + "\n").utf8))
  exit(error is CancellationError ? 130 : 1)
}
