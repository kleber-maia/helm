import Foundation
import Combine

/// Watches all files used to determine repository config settings.
final class ConfigWatcher
{
  weak var repository: HelmRepository?
  private(set) var repoConfigStream: FileEventStream! = nil
  private(set) var userConfigStream: FileEventStream! = nil
  private(set) var globalConfigStream: FileEventStream! = nil

  private var configSubject = PassthroughSubject<Void, Never>()

  var configPublisher: AnyPublisher<Void, Never>
  { configSubject.eraseToAnyPublisher() }
  
  init(repository: HelmRepository)
  {
    self.repository = repository
    repoLogger.publicInfo("watcher init type=config path=\(repository.repoURL.path)")
    
    var pathBuf = git_buf()
    var result: Int32
    let callback = {
      [weak self]
      (paths: [String]) -> Void in
      self?.observeEvents(paths)
    }
    
    result = git_repository_item_path(&pathBuf, repository.gitRepo,
                                      GIT_REPOSITORY_ITEM_CONFIG)
    if result == 0 {
      defer {
        git_buf_free(&pathBuf)
      }
      
      let repoPath = String(cString: pathBuf.ptr)
      
      repoLogger.publicDebug("watcher start type=repoConfig path=\(repoPath)")
      repoConfigStream = FileEventStream(path: repoPath,
                                         excludePaths: [],
                                         queue: .main,
                                         callback: callback)
    }
    userConfigStream = FileEventStream(path: "~/.gitconfig".expandingTildeInPath,
                                       excludePaths: [],
                                       queue: .main,
                                       callback: callback)
    repoLogger.publicDebug("watcher start type=userConfig path=~/.gitconfig")
    globalConfigStream = FileEventStream(path: "/etc/gitconfig",
                                         excludePaths: [], queue: .main,
                                         callback: callback)
    repoLogger.publicDebug("watcher start type=globalConfig path=/etc/gitconfig")
  }
  
  func stop()
  {
    repoLogger.publicInfo("watcher stop type=config")
    repoConfigStream.stop()
    userConfigStream.stop()
    globalConfigStream.stop()
  }
  
  private func observeEvents(_ paths: [String])
  {
    guard let repository = self.repository
    else { return }
    
    repoLogger.publicInfo("""
        watcher send type=config count=\(paths.count) \
        paths=\(paths.joined(separator: ","))
        """)
    repository.config.invalidate()
    configSubject.send()
  }
}
