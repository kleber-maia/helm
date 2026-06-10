import Foundation
import Combine

final class WorkspaceWatcher
{
  weak var controller: (any RepositoryController)?
  private(set) var stream: FileEventStream! = nil
  var skipIgnored = true

  private let subject = PassthroughSubject<[String], Never>()
  var publisher: AnyPublisher<[String], Never> { subject.eraseToAnyPublisher() }
  
  init?(controller: any RepositoryController)
  {
    self.controller = controller
    
    guard let repository = controller.repository as? HelmRepository,
          let stream = FileEventStream(
        path: repository.repoURL.path,
        excludePaths: [repository.gitDirectoryPath],
        queue: controller.queue.queue,
        callback: { [weak self] (paths) in self?.observeEvents(paths) })
    else { return nil }
    
    repoLogger.publicInfo("""
        watcher init type=workspace path=\(repository.repoURL.path) \
        gitPath=\(repository.gitDirectoryPath)
        """)
    self.stream = stream
  }
  
  deinit
  {
    stop()
  }
  
  func stop()
  {
    repoLogger.publicInfo("watcher stop type=workspace")
    stream.stop()
  }
  
  func observeEvents(_ paths: [String])
  {
    guard let controller = self.controller,
          let repository = controller.repository as? FileStatusDetection
    else { return }
    let changedPaths: [String]
  
    if skipIgnored {
      let filteredPaths = paths.filter { !repository.isIgnored(path: $0) }
      guard !filteredPaths.isEmpty
      else {
        repoLogger.publicDebug("""
            watcher workspace ignoredAll count=\(paths.count)
            """)
        return
      }
      
      changedPaths = filteredPaths
    }
    else {
      changedPaths = paths
    }
  
    repoLogger.publicInfo("""
        watcher send type=workspace count=\(changedPaths.count) \
        paths=\(changedPaths.joined(separator: ","))
        """)
    self.subject.send(changedPaths)
  }
}
