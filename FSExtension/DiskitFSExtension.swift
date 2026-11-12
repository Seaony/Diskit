import ExtensionFoundation
import FSKit
import Foundation

@main
struct DiskitFSExtension: UnaryFileSystemExtension {
  var fileSystem: DiskitFileSystem { DiskitFileSystem() }
}
