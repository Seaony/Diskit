import ExtensionFoundation
import FSKit
import Foundation

@main
struct KayoiFSExtension: UnaryFileSystemExtension {
  var fileSystem: KayoiFileSystem { KayoiFileSystem() }
}
