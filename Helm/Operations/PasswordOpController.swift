import Cocoa
import Combine

/// An operation that may require a password.
class PasswordOpController: SimpleOperationController
{
  let urlInfo: Box<(host: String, path: String, port: Int)> = .init(("", "", 80))
  private(set) var passwordController: PasswordPanelController?
  private var closeSink: AnyCancellable?

  required init(windowController: HelmWindowController)
  {
    super.init(windowController: windowController)
    
    let nc = NotificationCenter.default
    
    closeSink = nc.publisher(for: NSWindow.willCloseNotification,
                             object: windowController.window).sinkOnMainQueue {
      [weak self] (_) in
      self?.abort()
    }
  }

  override func abort()
  {
    passwordController = nil
  }
  
  /// User/password callback
  nonisolated
  func getPassword() -> (String, String)?
  {
    let started = Date()

    repoLogger.publicInfo("password callback begin")
    guard !Thread.isMainThread
    else {
      repoLogger.publicError("password callback failed reason=mainThread")
      assertionFailure("password callback on main thread")
      return nil
    }
    guard DispatchQueue.main.sync(execute: { 
      MainActor.assumeIsolated { passwordController == nil }
    })
    else {
      repoLogger.publicError("password callback failed reason=sheetAlreadyOpen")
      assertionFailure("already have a password sheet")
      return nil
    }
    let (window, controller) = DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        let controller = PasswordPanelController()
        self.passwordController = controller
        return (windowController?.window, controller)
      }
    }
    guard let window = window,
          let urlInfo = self.urlInfo.value
    else {
      repoLogger.publicError("password callback failed reason=missingWindow")
      return nil
    }
    
    let result = controller.getPassword(parentWindow: window,
                                        host: urlInfo.host,
                                        path: urlInfo.path,
                                        port: UInt16(urlInfo.port))

    repoLogger.publicInfo("""
        password callback end result=\(result == nil ? "nil" : "credentials") \
        duration=\(Date().timeIntervalSince(started))
        """)
    return result
  }
  
  func setKeychainInfo(from url: URL)
  {
    urlInfo.value = (url.host ?? "", url.path, url.port ?? url.defaultPort)
  }
}
