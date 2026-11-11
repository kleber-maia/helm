import Foundation

/// A terminal's reported directory is title context, not a request to change
/// the repository displayed in the Git sidebar. No shell startup files change.
@MainActor
final class TerminalDirectoryTitle
{
  private struct Context: Sendable
  {
    var title: String
    var gitPaths: [String]
  }

  private let changed: (String?) -> Void
  private let queue = DispatchQueue(label: "helm.terminal-title", qos: .utility)
  private var directory: URL?
  private var generation = 0
  private var stopped = false
  private var paths: [String] = []
  private var streams: [FileEventStream] = []

  init(changed: @escaping (String?) -> Void)
  {
    self.changed = changed
  }

  func update(directory: URL?)
  {
    guard !stopped else { return }
    generation += 1
    self.directory = directory
    changed(nil)
    setWatchedPaths([])
    refresh()
  }

  func stop()
  {
    stopped = true
    generation += 1
    setWatchedPaths([])
  }

  private func refresh()
  {
    guard !stopped, let directory else { return }
    let expected = generation
    queue.async {
      let context = Self.read(directory)
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.stopped, self.generation == expected
        else { return }
        self.changed(context.title)
        self.setWatchedPaths(context.gitPaths)
      }
    }
  }

  private func setWatchedPaths(_ paths: [String])
  {
    guard paths != self.paths else { return }
    streams.forEach { $0.stop() }
    streams.removeAll()
    self.paths = paths
    for path in paths {
      if let stream = FileEventStream(path: path,
          excludePaths: [path + "/objects"], queue: .main,
          callback: { [weak self] changed in
        if changed.isEmpty || changed.contains(where: {
          $0.hasSuffix("HEAD") || $0.contains("/refs/") ||
          $0.hasSuffix("packed-refs") || $0 == path
        }) {
          self?.refresh()
        }
      }) {
        streams.append(stream)
      }
    }
  }

  private nonisolated static func read(_ directory: URL) -> Context
  {
    let folder = directory.lastPathComponent
    var repository: OpaquePointer?
    guard git_repository_open_ext(&repository, directory.path, 0, nil) == 0,
          let repository else {
      return .init(title: folder, gitPaths: [])
    }
    defer { git_repository_free(repository) }
    let paths = [git_repository_path(repository),
                 git_repository_commondir(repository)].compactMap {
      $0.map { URL(fileURLWithPath: String(cString: $0)).path }
    }
    var head: OpaquePointer?
    var suffix: String?
    if git_repository_head(&head, repository) == 0, let head {
      defer { git_reference_free(head) }
      if git_repository_head_detached(repository) == 1,
         let oid = git_reference_target(head) {
        suffix = "HEAD@" + String(cString: git_oid_tostr_s(oid)).prefix(7)
      }
      else if let name = git_reference_shorthand(head) {
        suffix = String(cString: name)
      }
    }
    return .init(title: suffix.map { "\(folder)/\($0)" } ?? folder,
                 gitPaths: Array(Set(paths)).sorted())
  }
}
