import Core
import Foundation

struct CLIArguments: Sendable {
  let command: String
  let connectionID: UUID?
  let operands: [String]
  let showHidden: Bool
  let recursive: Bool
  let range: Range<Int64>?
  // 像 Finder 一样经过挂载卷的读取逻辑、每次读 1 MiB，用来测复制速度
  let finderReads: Bool

  init(_ arguments: [String]) throws {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
      command = "help"
      connectionID = nil
      operands = []
      showHidden = false
      recursive = false
      range = nil
      finderReads = false
      return
    }
    let command = arguments[0]
    var positional: [String] = []
    var all = false
    var recursive = false
    var range: Range<Int64>?
    var finderReads = false
    var options = true
    var index = 1
    while index < arguments.count {
      let argument = arguments[index]
      if options, argument == "--" {
        options = false
      } else if options, command == "ls", argument == "-a" {
        all = true
      } else if options, command == "rm", argument == "-r" {
        recursive = true
      } else if options, command == "cat", argument == "--finder" {
        finderReads = true
      } else if options, command == "cat", argument == "--range" {
        guard range == nil, index + 1 < arguments.count else { throw RemoteError.invalidPath }
        index += 1
        let bounds = arguments[index].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let lower = Int64(bounds[0]), let upper = Int64(bounds[1]),
          lower >= 0, upper >= lower, upper < Int64.max
        else { throw RemoteError.invalidPath }
        range = lower..<(upper + 1)
      } else {
        positional.append(argument)
      }
      index += 1
    }
    let id: UUID?
    if command == "devices" {
      guard positional.isEmpty else { throw RemoteError.invalidPath }
      id = nil
    } else if command == "pair" {
      guard positional.count == 2 else { throw RemoteError.invalidPath }
      id = nil
    } else {
      let counts = [
        "ls": 1, "stat": 1, "get": 2, "put": 2, "mkdir": 1, "rm": 1, "mv": 2, "df": 0, "cat": 1,
      ]
      guard let count = counts[command], positional.count == count + 1,
        let value = UUID(uuidString: positional[0])
      else { throw RemoteError.invalidPath }
      id = value
      positional.removeFirst()
    }
    self.command = command
    connectionID = id
    operands = positional
    showHidden = all
    self.recursive = recursive
    self.range = range
    self.finderReads = finderReads
  }
}
