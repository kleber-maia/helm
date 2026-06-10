import Foundation
import Combine

/// Watches the repository for changes on disk, and publishes them.
final class RepositoryWatcher
{
  public enum RefKey
  {
    static let added = "addedRefs"
    static let deleted = "deletedRefs"
    static let changed = "changedRefs"
  }

  weak var controller: RepositoryController?
  
  var repository: HelmRepository? { controller?.repository as? HelmRepository }

  // stream must be var because we have to reference self to initialize it.
  var stream: FileEventStream! = nil
  var packedRefsWatcher: FileMonitor?
  var stashWatcher: FileMonitor?

  enum Notification: CaseIterable
  {
    case head, index, refLog, refs, stash
  }

  let publishers = PublisherGroup<Void, Never, Notification>()

  let mutex = NSRecursiveLock()
  
  private var lastIndexChangeGuarded = Date()
  var lastIndexChange: Date
  {
    get
    { mutex.withLock { lastIndexChangeGuarded } }
    set
    {
      mutex.withLock {
        lastIndexChangeGuarded = newValue
        controller?.invalidateIndex()
        repoLogger.publicInfo("watcher send type=index modified=\(newValue)")
        publishers.send(.index)
      }
    }
  }
  
  var refsCache: [GeneralRefName: GitOID]

  var packedRefsSink, stashSink: AnyCancellable?

  init?(controller: RepositoryController)
  {
    guard let repository = controller.repository as? HelmRepository
    else { return nil }
    
    self.controller = controller
    self.refsCache = Self.index(from: repository)
    repoLogger.publicInfo("""
        watcher init type=repository path=\(repository.gitDirectoryPath) \
        refs=\(self.refsCache.count)
        """)

    let gitPath = repository.gitDirectoryPath
    let objectsPath = gitPath.appending(pathComponent: "objects")
    guard let stream = FileEventStream(path: gitPath,
                                       excludePaths: [objectsPath],
                                       queue: controller.queue.queue,
                                       callback: {
      [weak self] (paths) in
      // Capture the repository here in case it gets deleted on another thread
      guard let self = self,
            let repository = self.controller?.repository as? HelmRepository
      else { return }
      
      self.observeEvents(paths, repository)
    })
    else { return nil }
  
    self.stream = stream
    makePackedRefsWatcher()
    makeStashWatcher()
  }
  
  func stop()
  {
    repoLogger.publicInfo("watcher stop type=repository")
    stream.stop()
    mutex.withLock {
      packedRefsWatcher = nil
    }
  }
  
  func makePackedRefsWatcher()
  {
    let path = repository!.gitDirectoryPath
    let watcher = FileMonitor(path: path +/ "packed-refs")
    
    if let watcher {
      repoLogger.publicInfo("watcher start type=packedRefs path=\(path +/ "packed-refs")")
      mutex.withLock { packedRefsWatcher = watcher }
      packedRefsSink = watcher.eventPublisher.sink {
        [weak self] (_, _) in
        repoLogger.publicInfo("watcher event type=packedRefs")
        self?.checkRefs()
      }
    }
    else {
      repoLogger.publicDebug("watcher missing type=packedRefs path=\(path +/ "packed-refs")")
    }
  }
  
  func makeStashWatcher()
  {
    let path = repository!.gitDirectoryPath +/ "logs/refs/stash"
    guard let watcher = FileMonitor(path: path)
    else {
      repoLogger.publicDebug("watcher missing type=stash path=\(path)")
      return
    }
    
    repoLogger.publicInfo("watcher start type=stash path=\(path)")
    stashWatcher = watcher
    stashSink = watcher.eventPublisher.sink {
      [weak self] (_, _) in
      repoLogger.publicInfo("watcher send type=stash")
      self?.publishers.send(.stash)
    }
  }
  
  static func index(from repository: HelmRepository) -> [GeneralRefName: GitOID]
  {
    let refs = repository.allRefs()
    var result = [GeneralRefName: GitOID]()

    for ref in refs {
      guard let oid = repository.sha(forRef: ref).flatMap({ GitOID(sha: $0) })
      else { continue }
      
      result[ref] = oid
    }
    return result
  }
  
  func checkIndex(repository: HelmRepository)
  {
    let gitPath = repository.gitDirectoryPath
    let indexPath = gitPath.appending(pathComponent: "index")
    guard let indexAttributes = try? FileManager.default
                                     .attributesOfItem(atPath: indexPath),
          let newMod = indexAttributes[FileAttributeKey.modificationDate]
                       as? Date
    else {
      repoLogger.publicError("watcher index missing path=\(indexPath)")
      lastIndexChange = Date.distantPast
      return
    }
    
    if lastIndexChange.compare(newMod) != .orderedSame {
      lastIndexChange = newMod
    }
  }
  
  func paths(_ paths: [String], includeSubpaths subpaths: [String]) -> Bool
  {
    for path in paths {
      for subpath in subpaths {
        if path.hasSuffix(subpath) ||
           path.deletingLastPathComponent.hasSuffix(subpath) {
          return true
        }
      }
    }
    return false
  }
  
  func checkRefs(changedPaths: [String], repository: HelmRepository)
  {
    mutex.withLock {
      if packedRefsWatcher == nil,
         changedPaths.contains(repository.gitDirectoryPath) {
        makePackedRefsWatcher()
      }
    }

    let refPaths = [
      "refs/heads",
      "refs/remotes",
      "refs/tags",
    ]
    
    if paths(changedPaths, includeSubpaths: refPaths) {
      repoLogger.publicInfo("""
          watcher refsPathChanged count=\(changedPaths.count) \
          paths=\(changedPaths.joined(separator: ","))
          """)
      checkRefs()
    }
  }
  
  func checkHead(changedPaths: [String], repository: HelmRepository)
  {
    if paths(changedPaths, includeSubpaths: ["HEAD"]) {
      repoLogger.publicInfo("watcher send type=head")
      repository.clearCachedBranch()
      publishers.send(.head)
    }
  }
  
  func checkRefs()
  {
    guard let repository = self.repository
    else { return }
    
    mutex.lock()
    defer { mutex.unlock() }
    
    let newRefCache = Self.index(from: repository)
    let newKeys = Set(newRefCache.keys)
    let oldKeys = Set(refsCache.keys)
    let addedRefs = newKeys.subtracting(oldKeys)
    let deletedRefs = oldKeys.subtracting(newKeys)
    let changedRefs = newKeys.subtracting(addedRefs).filter {
      (ref) -> Bool in
      guard let oldOID = refsCache[ref],
            let newSHA = repository.sha(forRef: ref),
            let newOID =  GitOID(sha: newSHA)
      else { return false }
      
      return oldOID != newOID
    }
    
    var refChanges = [String: Set<GeneralRefName>]()
    
    if !addedRefs.isEmpty {
      refChanges[RefKey.added] = addedRefs
    }
    if !deletedRefs.isEmpty {
      refChanges[RefKey.deleted] = deletedRefs
    }
    if !changedRefs.isEmpty {
      refChanges[RefKey.changed] = Set(changedRefs)
    }
    
    if !refChanges.isEmpty {
      repoLogger.publicInfo("""
          watcher send type=refs added=\(addedRefs.count) \
          deleted=\(deletedRefs.count) changed=\(changedRefs.count)
          """)
      repository.rebuildRefsIndex()
      repository.refsChanged()
      publishers.send(.refs)
    }
    
    refsCache = newRefCache
  }

  func resetRefsCache()
  {
    guard let repository = self.repository
    else { return }

    mutex.withLock {
      refsCache = Self.index(from: repository)
      repoLogger.publicDebug("watcher resetRefsCache refs=\(self.refsCache.count)")
    }
  }
  
  func checkLogs(changedPaths: [String])
  {
    if paths(changedPaths, includeSubpaths: ["logs/refs"]) {
      repoLogger.publicInfo("watcher send type=refLog")
      publishers.send(.refLog)
    }
  }
  
  func observeEvents(_ paths: [String], _ repository: HelmRepository)
  {
    // FSEvents includes trailing slashes, but some other APIs don't.
    let standardizedPaths = paths.map { ($0 as NSString).standardizingPath }

    repoLogger.publicDebug("""
        watcher event type=repository count=\(standardizedPaths.count) \
        paths=\(standardizedPaths.joined(separator: ","))
        """)
  
    checkIndex(repository: repository)
    checkHead(changedPaths: standardizedPaths, repository: repository)
    checkRefs(changedPaths: standardizedPaths, repository: repository)
    checkLogs(changedPaths: standardizedPaths)
  }
}
