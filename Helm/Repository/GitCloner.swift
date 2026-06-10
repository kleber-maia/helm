import Foundation

public final class GitCloner: Cloning
{
  public init() {}
  
  @discardableResult
  public func clone(from source: URL, to destination: URL,
                    branch: String,
                    recurseSubmodules: Bool,
                    publisher: RemoteProgressPublisher) throws
    -> (any FullRepository)?
  {
    guard let gitPath = HelmRepository.gitPath()
    else { throw RepoError.unexpected }

    let started = Date()
    var args = ["clone"]

    if !branch.isEmpty {
      args += ["--branch", branch]
    }
    if recurseSubmodules {
      args.append("--recurse-submodules")
    }
    args += [source.absoluteString, destination.path]

    repoLogger.publicInfo("""
        clone begin source=\(source.absoluteString) destination=\(destination.path) \
        branch=\(branch.isEmpty ? "[default]" : branch) recurse=\(recurseSubmodules)
        """)

    do {
      let runner = CLIRunner(toolPath: gitPath,
                             workingDir: destination.deletingLastPathComponent().path)

      _ = try runner.run(args: args)
      guard let repo = HelmRepository(url: destination)
      else { throw RepoError.unexpected }

      publisher.finished()
      repoLogger.publicInfo("""
          clone end destination=\(destination.path) \
          duration=\(Date().timeIntervalSince(started))
          """)
      return repo
    }
    catch let error as RepoError {
      publisher.error(error)
      repoLogger.publicError("""
          clone failed destination=\(destination.path) \
          duration=\(Date().timeIntervalSince(started)) \
          error=\(String(describing: error))
          """)
      throw error
    }
    catch {
      publisher.error(.unexpected)
      repoLogger.publicError("""
          clone failed destination=\(destination.path) \
          duration=\(Date().timeIntervalSince(started)) \
          error=\(String(describing: error))
          """)
      throw error
    }
  }
}
