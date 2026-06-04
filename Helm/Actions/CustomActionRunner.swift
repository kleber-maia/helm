import AppKit
import os

private let actionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "customAction")

/// Runs a custom action's commands via bash in the
/// repository's working directory.
enum CustomActionRunner
{
  @MainActor
  static func run(_ action: CustomAction,
                  in workingDirectory: String,
                  window: NSWindow? = nil)
  {
    let spinner = window.flatMap { findSpinner(in: $0) }

    spinner?.isHidden = false
    spinner?.startAnimation(nil)

    Task.detached {
      actionLogger.info(
          "Running action '\(action.name)' in \(workingDirectory)")

      let task = Process()
      let shell = ProcessInfo.processInfo
          .environment["SHELL"] ?? "/bin/zsh"

      task.executableURL = URL(fileURLWithPath: shell)
      task.arguments = ["-l", "-c", action.commands]
      task.currentDirectoryURL =
          URL(fileURLWithPath: workingDirectory)

      let outputPipe = Pipe()
      let errorPipe = Pipe()

      task.standardOutput = outputPipe
      task.standardError = errorPipe

      do {
        try task.run()

        // Drain both pipes concurrently: a subprocess that fills
        // stderr while we're still reading stdout would otherwise
        // block on its stderr write and deadlock.
        async let outputData = Task.detached {
          outputPipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        async let errorData = Task.detached {
          errorPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        let outData = await outputData
        let errData = await errorData

        task.waitUntilExit()

        let output = String(
            data: outData, encoding: .utf8) ?? ""
        let errorOutput = String(
            data: errData, encoding: .utf8) ?? ""

        await MainActor.run { spinner?.stopAnimation(nil) }
        await MainActor.run { spinner?.isHidden = true }

        if task.terminationStatus != 0 {
          let message = errorOutput.isEmpty
              ? output : errorOutput

          actionLogger.error(
              "Action '\(action.name)' failed (exit \(task.terminationStatus)): \(message)")
          await showError(
              action: action,
              message: message.isEmpty
                  ? "Exit code \(task.terminationStatus)"
                  : message,
              window: window)
        }
        else {
          actionLogger.info(
              "Action '\(action.name)' completed")
        }
      }
      catch {
        await MainActor.run { spinner?.stopAnimation(nil) }
        await MainActor.run { spinner?.isHidden = true }
        actionLogger.error(
            "Action '\(action.name)' launch failed: \(error.localizedDescription)")
        await showError(
            action: action,
            message: error.localizedDescription,
            window: window)
      }
    }
  }

  // NSAlert runs Autolayout over informativeText as a single
  // sized text field — a multi-KB blob (e.g. a verbose failing
  // command's stderr) wedges the main thread for tens of seconds.
  // The actual failure message is usually at the tail.
  private static let maxErrorMessageLength = 1000

  @MainActor
  private static func showError(
      action: CustomAction,
      message: String,
      window: NSWindow?)
  {
    let alert = NSAlert()
    let displayMessage = message.count > maxErrorMessageLength
        ? "… (output truncated)\n\n"
            + String(message.suffix(maxErrorMessageLength))
        : message

    alert.alertStyle = .warning
    alert.messageText =
        "Action \"\(action.name)\" failed"
    alert.informativeText = displayMessage

    if let window {
      alert.beginSheetModal(for: window)
    }
    else {
      alert.runModal()
    }
  }

  @MainActor
  private static func findSpinner(
      in window: NSWindow) -> NSProgressIndicator?
  {
    guard let toolbar = window.toolbar
    else { return nil }

    for item in toolbar.items
        where item.itemIdentifier == .spinner {
      return item.view as? NSProgressIndicator
    }
    return nil
  }
}
