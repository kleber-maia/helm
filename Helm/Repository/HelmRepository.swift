import Foundation
import Combine
import os

public let repoLogger = Logger(subsystem: Bundle.main.bundleIdentifier!,
                               category: "repo")

extension Logger
{
  func publicDebug(_ message: String)
  {
    debug("\(message, privacy: .public)")
  }

  func publicInfo(_ message: String)
  {
    info("\(message, privacy: .public)")
  }

  func publicError(_ message: String)
  {
    error("\(message, privacy: .public)")
  }
}

/// Stores a repo reference for C callbacks
struct CallbackPayload { let repo: HelmRepository }

public final class HelmRepository: BasicRepository, RepoConfiguring
{
  let gitRepo: OpaquePointer
  @objc public let repoURL: URL
  let gitRunner: CLIRunner
  let mutex = NSRecursiveLock()
  var refsIndex = [SHA: [String]]()

  let currentBranchSubject = CurrentValueSubject<LocalBranchRefName?, Never>(nil)
  
  public weak var controller: RepositoryController? = nil
  
  /// Dedicated leaf lock for the `isWriting` flag. It is only ever held for
  /// the trivial duration of reading or writing the bool below — never while
  /// acquiring `mutex` or `objc_sync(self)`. Keeping it a leaf prevents the
  /// lock-ordering cycle that previously deadlocked the app: `executeGit`
  /// holds `objc_sync(self)` and used to take `mutex` (via `updateIsWriting`)
  /// to flip this flag, while `performReading`/`performWriting` hold `mutex`
  /// and then shell out to CLI git (`objc_sync(self)`) — opposite orders.
  private let writeStateLock = NSLock()
  private var isWritingStorage = false

  public var isWriting: Bool
  { writeStateLock.withLock { isWritingStorage } }

  var cachedStagedChanges: [FileChange]?
  {
    get { controller?.cache.stagedChanges }
    set { controller?.cache.stagedChanges = newValue }
  }
  var cachedAmendChanges: [FileChange]?
  {
    get { controller?.cache.amendChanges }
    set { controller?.cache.amendChanges = newValue }
  }
  var cachedUnstagedChanges: [FileChange]?
  {
    get { controller?.cache.unstagedChanges }
    set { controller?.cache.unstagedChanges = newValue }
  }
  var cachedBranches: [String: GitBranch]
  {
    get { controller?.cache.branches ?? [:] }
    set { controller?.cache.branches = newValue }
  }
  var cachedIgnored = false

  let diffCache = Cache<String, any Diff>(maxSize: 50)
  public let config: any Config
  
  var gitDirectoryPath: String
  {
    guard let path = git_repository_path(gitRepo)
    else { return "" }
    
    return String(cString: path)
  }

  /// Call at startup for global initialization. (Initializes libgit2)
  public static func initialize()
  {
    git_libgit2_init()
  }

  static func gitPath() -> String?
  {
    let paths = ["/usr/bin/git", "/usr/local/git/bin/git"]
    
    return paths.first { FileManager.default.fileExists(atPath: $0) }
  }

  public init(gitRepo: OpaquePointer) throws
  {
    guard let gitCmd = HelmRepository.gitPath(),
          let workDirPath = git_repository_workdir(gitRepo),
          let config = GitConfig(repository: gitRepo)
    else { throw RepoError.unexpected }
    let url = URL(fileURLWithPath: String(cString: workDirPath))

    self.gitRepo = gitRepo
    self.repoURL = url
    self.gitRunner = CLIRunner(toolPath: gitCmd,
                               workingDir: url.path)
    self.config = config
    repoLogger.publicInfo("repository open path=\(url.path)")
  }
  
  @objc(initWithURL:)
  public convenience init?(url: URL)
  {
    guard url.isFileURL
    else { return nil }
    let path = (url.path as NSString).fileSystemRepresentation
    guard let repo = try? OpaquePointer.from({
      git_repository_open(&$0, path) })
    else { return nil }

    do {
      try self.init(gitRepo: repo)
    }
    catch {
      return nil
    }
  }
  
  public convenience init(emptyURL url: URL) throws
  {
    let path = (url.path as NSString).fileSystemRepresentation
    let repo = try OpaquePointer.from({
      git_repository_init(&$0, path, 0) })

    try self.init(gitRepo: repo)
  }
  
  func addCachedBranch(_ branch: GitBranch)
  {
    controller?.cache.branches[branch.name] = branch
  }
  
  func updateIsWriting(_ writing: Bool)
  {
    writeStateLock.withLock {
      guard writing != isWritingStorage
      else { return }

      isWritingStorage = writing
      repoLogger.publicDebug("""
          repository writingState path=\(self.repoURL.path) writing=\(writing)
          """)
    }
  }

  /// Atomically marks a write as started, returning `false` if one is already
  /// in progress. Both the libgit2 (`performWriting`) and CLI (`writing`)
  /// paths funnel their "already writing?" guard through this single leaf
  /// lock, so they correctly exclude each other without nesting locks.
  private func beginWriting() -> Bool
  {
    writeStateLock.withLock {
      guard !isWritingStorage
      else { return false }

      isWritingStorage = true
      return true
    }
  }

  private func endWriting()
  {
    writeStateLock.withLock { isWritingStorage = false }
  }
    
  func clearCachedBranch()
  {
    mutex.withLock {
      repoLogger.publicDebug("repository clearCachedBranch path=\(self.repoURL.path)")
      currentBranchSubject.value = nil
    }
  }

  func updateCurrentBranch(reason: String)
  {
    mutex.withLock {
      let newBranch = calculateCurrentBranch()
      guard newBranch != currentBranchSubject.value
      else {
        repoLogger.publicDebug("""
            repository currentBranchUnchanged path=\(self.repoURL.path) \
            reason=\(reason)
            """)
        return
      }

      repoLogger.publicInfo("""
          repository currentBranchChanged path=\(self.repoURL.path) \
          reason=\(reason) branch=\(newBranch?.fullPath ?? "[none]")
          """)
      currentBranchSubject.value = newBranch
    }
  }
  
  func refsChanged()
  {
    repoLogger.publicDebug("repository refsChanged requested path=\(self.repoURL.path)")
    cachedBranches = [:]
    updateCurrentBranch(reason: "refsChanged")
  }

  func tryRefsChanged() -> Bool
  {
    guard mutex.try()
    else {
      repoLogger.publicError("""
          repository tryRefsChanged lockBusy path=\(self.repoURL.path)
          """)
      return false
    }

    defer { mutex.unlock() }
    repoLogger.publicDebug("repository tryRefsChanged locked path=\(self.repoURL.path)")
    rebuildRefsIndex()
    refsChanged()
    return true
  }
  
  func invalidateIndex()
  {
    repoLogger.publicDebug("repository invalidateIndex path=\(self.repoURL.path)")
    controller?.invalidateIndex()
  }
  
  func writing<T>(_ block: () throws -> T) throws -> T
  {
    let started = Date()

    repoLogger.publicDebug("repository writing request path=\(self.repoURL.path)")
    // libgit2 writes serialize on `mutex`, the same lock guarding
    // `performReading`/`performWriting`, so all libgit2 access against the
    // shared `git_repository` is mutually exclusive. `objc_sync(self)` is
    // reserved exclusively for serializing CLI git subprocesses
    // (`executeGit`); mixing the two here previously let a libgit2 write run
    // concurrently with a libgit2 read.
    return try mutex.withLock {
      guard beginWriting()
      else {
        repoLogger.publicError("""
            repository writing rejected path=\(self.repoURL.path) \
            reason=alreadyWriting
            """)
        throw RepoError.alreadyWriting
      }

      repoLogger.publicInfo("repository writing begin path=\(self.repoURL.path)")
      defer {
        endWriting()
        repoLogger.publicInfo("""
            repository writing end path=\(self.repoURL.path) \
            duration=\(Date().timeIntervalSince(started))
            """)
      }
      do {
        return try block()
      }
      catch {
        repoLogger.publicError("""
            repository writing failed path=\(self.repoURL.path) \
            error=\(String(describing: error))
            """)
        throw error
      }
    }
  }
  
  func executeGit(args: [String],
                  stdIn: String?,
                  writes: Bool,
                  network: Bool = false) throws -> Data
  {
    return try executeGit(args: args,
                          stdInData: stdIn?.data(using: .utf8),
                          writes: writes,
                          network: network)
  }

  /// Runs a git CLI command.
  /// - parameter network: Pass `true` for operations that talk to a remote
  ///   (push/fetch/clone). Local operations mutate `.git` state (index, refs,
  ///   objects) that libgit2 also reads, so they serialize on `mutex` to be
  ///   mutually exclusive with libgit2 reads/writes — a `git add` rewriting
  ///   the index must not race a concurrent libgit2 index read, which
  ///   produced torn/empty diffs. Local commands are fast, so briefly
  ///   blocking reads is correct. Network commands can run for a long time;
  ///   holding `mutex` across the transfer would beachball the UI, so they
  ///   keep their own `objc_sync(self)` serialization and never take `mutex`.
  func executeGit(args: [String],
                  stdInData: Data? = nil,
                  writes: Bool,
                  network: Bool = false) throws -> Data
  {
    guard FileManager.default.fileExists(atPath: repoURL.path)
    else {
      throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                    userInfo: nil)
    }

    let command = "git \(args.joined(separator: " "))"
    let started = Date()

    repoLogger.publicInfo("""
        repository git begin path=\(self.repoURL.path) writes=\(writes) \
        network=\(network) inputBytes=\(stdInData?.count ?? 0) command=\(command)
        """)

    func runCommand() throws -> Data
    {
      if writes && isWriting {
        repoLogger.publicError("""
            repository git rejected path=\(self.repoURL.path) writes=\(writes) \
            reason=alreadyWriting command=\(command)
            """)
        throw RepoError.alreadyWriting
      }

      let wasWriting = isWriting

      updateIsWriting(wasWriting || writes)
      defer {
        updateIsWriting(wasWriting)
      }

      do {
        let output = try gitRunner.run(inputData: stdInData, args: args)

        repoLogger.publicInfo("""
            repository git end path=\(self.repoURL.path) writes=\(writes) \
            outputBytes=\(output.count) \
            duration=\(Date().timeIntervalSince(started)) command=\(command)
            """)
        return output
      }
      catch {
        repoLogger.publicError("""
            repository git failed path=\(self.repoURL.path) writes=\(writes) \
            duration=\(Date().timeIntervalSince(started)) command=\(command) \
            error=\(String(describing: error))
            """)
        throw error
      }
    }

    // Only a local *write* must exclude libgit2 access: it mutates .git
    // state (index/refs/objects) that libgit2 reads, so it serializes on
    // `mutex`. Local reads (e.g. a potentially slow `git blame`) and network
    // operations keep their own `objc_sync(self)` serialization and never
    // take `mutex`, so a slow command cannot block libgit2 reads / the UI.
    if writes && !network {
      return try mutex.withLock {
        try runCommand()
      }
    }
    else {
      objc_sync_enter(self)
      defer {
        objc_sync_exit(self)
      }
      return try runCommand()
    }
  }
}

extension HelmRepository: WritingManagement
{
  public func performWriting(_ block: (() throws -> Void)) throws
  {
    let started = Date()

    repoLogger.publicDebug("repository performWriting request path=\(self.repoURL.path)")
    try mutex.withLock {
      guard beginWriting()
      else {
        repoLogger.publicError("""
            repository performWriting rejected path=\(self.repoURL.path) \
            reason=alreadyWriting
            """)
        throw RepoError.alreadyWriting
      }
      repoLogger.publicInfo("repository performWriting begin path=\(self.repoURL.path)")
      defer {
        endWriting()
        repoLogger.publicInfo("""
            repository performWriting end path=\(self.repoURL.path) \
            duration=\(Date().timeIntervalSince(started))
            """)
      }
      do {
        try block()
      }
      catch {
        repoLogger.publicError("""
            repository performWriting failed path=\(self.repoURL.path) \
            error=\(String(describing: error))
            """)
        throw error
      }
    }
  }

  /// Serializes a read operation against the repository. All libgit2
  /// access must go through `performReading` or `performWriting` to
  /// prevent concurrent access to the underlying git_repository pointer.
  public func performReading<T>(
      _ block: () throws -> T) rethrows -> T
  {
    let started = Date()

    do {
      let result = try mutex.withLock {
        try block()
      }
      let duration = Date().timeIntervalSince(started)

      if duration > 1 {
        repoLogger.publicDebug("""
            repository slowRead path=\(self.repoURL.path) duration=\(duration)
            """)
      }
      return result
    }
    catch {
      repoLogger.publicError("""
          repository read failed path=\(self.repoURL.path) \
          error=\(String(describing: error))
          """)
      throw error
    }
  }
}

extension HelmRepository
{
  func graphBetween(local: GitOID, upstream: GitOID) -> GraphStatus?
  {
    var ahead = 0
    var behind = 0
    let graphResult = local.withUnsafeOID { localOID in
      upstream.withUnsafeOID { upstreamOID in
        git_graph_ahead_behind(&ahead, &behind, gitRepo,
                               localOID, upstreamOID)
      }
    }
    guard graphResult == 0
    else { return nil }
    
    return .init(ahead: ahead, behind: behind)
  }
  
  public func graphBetween(localBranch: LocalBranchRefName,
                           upstreamBranch: any ReferenceName) -> GraphStatus?
  {
    if let localOID = oid(forRef: localBranch),
       let upstreamOID = oid(forRef: upstreamBranch) {
      return graphBetween(local: localOID, upstream: upstreamOID)
    }
    else {
      return nil
    }
  }
}
