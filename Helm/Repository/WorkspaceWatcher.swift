import Foundation
import Combine

final class WorkspaceWatcher
{
  weak var controller: (any RepositoryController)?
  private(set) var stream: FileEventStream! = nil
  var skipIgnored = true

  private let subject: PassthroughSubject<[String], Never>
  private let batcher: WorkspaceEventBatcher
  var publisher: AnyPublisher<[String], Never> { subject.eraseToAnyPublisher() }

  init?(controller: any RepositoryController)
  {
    self.controller = controller

    let subject = PassthroughSubject<[String], Never>()
    self.subject = subject
    batcher = WorkspaceEventBatcher(delay: 1.0) { [weak subject] paths in
      repoLogger.publicInfo("""
          watcher send type=workspace count=\(paths.count) \
          paths=\(paths.joined(separator: ","))
          """)
      // Subscribers retain their existing main-queue scheduling and
      // invalidation-before-read order.
      subject?.send(paths)
    }

    guard let repository = controller.repository as? HelmRepository,
          let stream = FileEventStream(
        path: repository.repoURL.path,
        excludePaths: [repository.gitDirectoryPath],
        queue: controller.queue.queue,
        callback: { [weak self] paths in
          guard let self,
                let controller = self.controller
          else { return }

          controller.queue.executeOffMainThread { [weak self] in
            self?.observeEvents(paths)
          }
        })
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
    batcher.stop()
    repoLogger.publicInfo("watcher stop type=workspace")
    stream?.stop()
  }

  func observeEvents(_ paths: [String])
  {
    guard let controller = self.controller,
          let repository = controller.repository as? FileStatusDetection
    else { return }

    // Ignore checks stay on the repository's serialized task lane.
    guard let changedPaths = WorkspaceEventBatcher.relevantPaths(
        paths, skipIgnored: skipIgnored,
        isIgnored: { repository.isIgnored(path: $0) })
    else {
      repoLogger.publicDebug("""
          watcher workspace ignoredAll count=\(paths.count)
          """)
      return
    }

    batcher.receive(changedPaths)
  }
}
