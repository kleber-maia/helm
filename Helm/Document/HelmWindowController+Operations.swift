import Cocoa

enum RemoteOperationOption
{
  case all, new, currentBranch, named(String)
}

extension HelmWindowController
{
  /// Returns the new operation, if any, mostly because the generic type must
  /// be part of the signature.
  @discardableResult
  func startOperation<OperationType: SimpleOperationController>()
      -> OperationType?
  {
    return startOperation { OperationType(windowController: self) }
           as? OperationType
  }

  // TODO: factory usually references this controller, so pass it in
  @discardableResult
  func startOperation(factory: () -> OperationController)
      -> OperationController?
  {
    if let operation = currentOperation {
      NSLog("Can't start new operation, already have \(operation)")
      showErrorMessage(error: .alreadyWriting)
      return nil
    }
    else {
      let operation = factory()

      do {
        stopAutoFetch()
        currentOperation = operation
        try operation.start()
        return operation
      }
      catch let error as RepoError {
        currentOperation = nil
        showErrorMessage(error: error)
        startAutoFetch()
        return nil
      }
      catch {
        currentOperation = nil
        showErrorMessage(error: RepoError.unexpected)
        startAutoFetch()
        return nil
      }
    }
  }

  func showAlert(message: UIString, info: UIString)
  {
    guard let window = self.window
    else { return }
    let alert = NSAlert()

    alert.messageString = message
    alert.informativeString = info
    alert.beginSheetModal(for: window)
  }

  func showAlert(nsError: NSError)
  {
    guard let window = self.window
    else { return }
    let alert = NSAlert(error: nsError)

    alert.beginSheetModal(for: window)
  }

  /// Called by the operation controller when it's done.
  func operationEnded(_ operation: OperationController)
  {
    if currentOperation === operation {
      currentOperation = nil
      startAutoFetch()
    }
  }
}
