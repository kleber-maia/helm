import Cocoa

/// Takes charge of executing a command
@MainActor
class OperationController
{
  enum OperationResult
  {
    case success
    case failure
    case canceled
  }
  
  /// The window controller that initiated and owns the operation. May be nil
  /// if the window is closed before the operation completes.
  weak var windowController: HelmWindowController?
  /// Convenient reference to the repository from the window controller.
  weak var repository: (any FullRepository)?
  /// True if the operation is being canceled.
  nonisolated var canceled: Bool
  {
    get { canceledMutex.withLock { canceledBox.value } ?? false }
    set { canceledMutex.withLock { canceledBox.value = newValue } }
  }
  /// Actions to be executed after the operation succeeds.
  var successActions: [() -> Void] = []

  private let canceledMutex = NSRecursiveLock()
  private let canceledBox = Box<Bool>(false)

  nonisolated var operationName: String
  { String(describing: type(of: self)) }
  
  init(windowController: HelmWindowController)
  {
    self.windowController = windowController
    self.repository = windowController.repoDocument!.repository
  }
  
  /// Initiates the operation.
  func start() throws {}
  
  func abort() {}
  
  func ended(result: OperationResult = .success)
  {
    repoLogger.publicInfo("""
        operation ended name=\(self.operationName) result=\(String(describing: result))
        """)
    if result == .success {
      for action in successActions {
        action()
      }
    }
    successActions.removeAll()
    windowController?.operationEnded(self)
  }

  nonisolated func refsChangedAndEnded()
  {
    repoLogger.publicDebug("operation refsChangedAndEnded requested")
    Task {
      @MainActor in
      repoLogger.publicInfo("""
          operation refsChangedAndEnded running name=\(self.operationName)
          """)
      self.windowController?.repoController.refsChanged()
      self.ended()
    }
  }

  func onSuccess(_ action: @escaping () -> Void)
  {
    successActions.append(action)
  }
  
  /// Override to suppress errors.
  func shoudReport(error: NSError) -> Bool { return true }
  
  func repoErrorMessage(for error: RepoError) -> UIString
  {
    return error.message
  }
  
  /// Executes the given block on the repository queue, handling errors and
  /// updating status.
  func tryRepoOperation(block: @escaping (@Sendable () throws -> Void))
  {
    let operationName = self.operationName

    repoLogger.publicInfo("operation repoBlock enqueue name=\(operationName)")
    windowController?.repoController.queue.executeOffMainThread {
      [weak self] in
      let started = Date()

      repoLogger.publicInfo("operation repoBlock begin name=\(operationName)")
      do {
        try block()
        repoLogger.publicInfo("""
            operation repoBlock success name=\(operationName) \
            duration=\(Date().timeIntervalSince(started))
            """)
      }
      catch let error {
        guard let self = self
        else {
          repoLogger.publicError("""
              operation repoBlock failedAfterDeinit name=\(operationName) \
              error=\(String(describing: error))
              """)
          return
        }

        repoLogger.publicError("""
            operation repoBlock failed name=\(operationName) \
            duration=\(Date().timeIntervalSince(started)) \
            error=\(String(describing: error))
            """)
        
        Task { @MainActor in
          defer {
            self.ended(result: .failure)
          }

          switch error {

            case let repoError as RepoError:
              self.showFailureError(self.repoErrorMessage(for: repoError).rawValue)

            case let nsError as NSError where self.shoudReport(error: nsError):
              var message = error.localizedDescription

              if let gitError = GitError.last {
                message.append(" \(gitError.message)")
              }
              self.showFailureError(message)

            default:
              break
          }
        }
      }
    }
  }
  
  func showFailureError(_ message: String)
  {
    repoLogger.publicError("""
        operation showFailureError name=\(self.operationName) message=\(message)
        """)
    Task { @MainActor in
      NSAlert.showMessage(window: self.windowController?.window,
                          message: UIString(rawValue: message))
    }
  }

  func fail(with error: RepoError)
  {
    repoLogger.publicError("""
        operation fail name=\(self.operationName) error=\(String(describing: error))
        """)
    showFailureError(repoErrorMessage(for: error).rawValue)
    ended(result: .failure)
  }
}


/// For simple operations that won't need to be initialized with more parameters.
class SimpleOperationController: OperationController
{
  required override init(windowController: HelmWindowController)
  {
    super.init(windowController: windowController)
  }
}
