import Foundation
import Zsign

public enum LibraryDependencies {
  public static func list(_ url: URL) throws -> [String] {
    let executable = FileBehavior.executable(in: url) ?? url
    guard MachOInspector.hasMachOMagic(executable) else { throw SignerError("Select a Mach-O file or framework.") }
    return Zsign.listDylibs(appExecutable: executable.path)
  }
  public static func change(_ url: URL, from old: String, to new: String, workspace: Workspace, progress: Progress? = nil) throws {
    let executable = try workspace.confined(FileBehavior.executable(in: url) ?? url)
    guard !new.isEmpty, !new.contains("\0"), try list(url).contains(old) else { throw SignerError("Invalid library dependency.") }
    let work = workspace.temporary.appendingPathComponent(UUID().uuidString)
    try workspace.fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? workspace.fm.removeItem(at: work) }
    let staged = work.appendingPathComponent(executable.lastPathComponent)
    try FileTransfer.copy(executable, to: staged, progress: progress)
    guard Zsign.changeDylibPath(appExecutable: staged.path, for: old, with: new),
      Zsign.listDylibs(appExecutable: staged.path).contains(new) else { throw SignerError("Unable to update the dependency. The original file was retained.") }
    try FileTransfer.check(progress)
    _ = try workspace.fm.replaceItemAt(executable, withItemAt: staged)
  }
}
