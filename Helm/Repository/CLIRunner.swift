import Foundation
import os

let cliLogger = Logger(subsystem: Bundle.main.bundleIdentifier!,
                       category: "cli")

let HelmErrorDomainCLI = "cli"
let HelmErrorOutputKey = "output"
let HelmErrorErrorOutputKey = "errorOutput"
let HelmErrorArgsKey = "args"

/// Manages running a command line tool
public struct CLIRunner
{
  let toolPath: String
  let workingDir: String

  public init(toolPath: String, workingDir: String)
  {
    self.toolPath = toolPath
    self.workingDir = workingDir
  }
  
  /// Executes the command line tool with the given command and input data
  /// - Parameter inputData: String data for input, such as file contents
  /// - Parameter args: Command arguments to be passed
  public func run(inputString: String, args: [String]) throws -> Data
  {
    return try run(inputData: inputString.data(using: .utf8), args: args)
  }
  
  /// Executes the command line tool with the given command and input data
  /// - Parameter inputData: Data for input, such as file contents
  /// - Parameter args: Command arguments to be passed
  public func run(inputData: Data? = nil, args: [String]) throws -> Data
  {
    let started = Date()
    let command = "\((toolPath as NSString).lastPathComponent) " +
                  args.joined(separator: " ")

    cliLogger.publicInfo("""
        cli begin cwd=\(workingDir) inputBytes=\(inputData?.count ?? 0) \
        command=\(command)
        """)
    
    let task = Process()
    
    task.currentDirectoryPath = workingDir
    task.launchPath = toolPath
    task.arguments = args
    task.environment = Self.gitEnvironment()
    
    // Large files have to be chunked or else FileHandle.write() hangs
    let chunkSize = 10*1024

    if let data = inputData {
      let stdInPipe = Pipe()
      
      if data.count <= chunkSize {
        stdInPipe.fileHandleForWriting.write(data)
        stdInPipe.fileHandleForWriting.closeFile()
      }
      task.standardInput = stdInPipe
    }
    
    let pipe = Pipe()
    let errorPipe = Pipe()
    let outputReader = PipeReader(pipe: pipe, label: "stdout")
    let errorReader = PipeReader(pipe: errorPipe, label: "stderr")
    
    task.standardOutput = pipe
    task.standardError = errorPipe
    do {
      try task.run()
    }
    catch {
      cliLogger.publicError("""
          cli launch failed cwd=\(workingDir) command=\(command) \
          error=\(String(describing: error))
          """)
      throw error
    }
    outputReader.start()
    errorReader.start()
    
    if let data = inputData,
       data.count > chunkSize,
       let handle = (task.standardInput as? Pipe)?.fileHandleForWriting {
      for chunkIndex in 0...(data.count/chunkSize) {
        let chunkStart = chunkIndex * chunkSize
        let chunkEnd = min(chunkStart + chunkSize, data.count)
        let subData = data.subdata(in: chunkStart..<chunkEnd)
        
        handle.write(subData)
      }
      handle.closeFile()
    }
    
    task.waitUntilExit()
    let output = outputReader.waitForData()
    let errorOutput = errorReader.waitForData()
    
    guard task.terminationStatus == 0
    else {
      let string = String(data: output, encoding: .utf8) ?? "-"
      let errorString = String(data: errorOutput, encoding: .utf8) ?? "-"
      let description = Self.errorDescription(output: string,
                                              errorOutput: errorString,
                                              args: args,
                                              status: task.terminationStatus)
      
      cliLogger.publicError("""
          cli failed status=\(task.terminationStatus) \
          duration=\(Date().timeIntervalSince(started)) command=\(command)
          """)
      cliLogger.publicDebug("cli stdout=\(string)")
      cliLogger.publicDebug("cli stderr=\(errorString)")
      throw NSError(domain: HelmErrorDomainCLI, code: Int(task.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: description,
                               HelmErrorOutputKey: string,
                               HelmErrorErrorOutputKey: errorString,
                               HelmErrorArgsKey: args.joined(separator: " ")])
    }

    cliLogger.publicInfo("""
        cli end status=\(task.terminationStatus) outputBytes=\(output.count) \
        errorBytes=\(errorOutput.count) duration=\(Date().timeIntervalSince(started)) \
        command=\(command)
        """)
    return output
  }

  private static func errorDescription(output: String,
                                       errorOutput: String,
                                       args: [String],
                                       status: Int32) -> String
  {
    let trimmedError = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

    if !trimmedError.isEmpty {
      return trimmedError
    }
    if !trimmedOutput.isEmpty {
      return trimmedOutput
    }

    return "git \(args.joined(separator: " ")) failed with status \(status)."
  }

  private static func gitEnvironment() -> [String: String]
  {
    var environment = ProcessInfo.processInfo.environment
    let path = environment["PATH"] ?? ""
    let pathComponents = path.split(separator: ":").map(String.init)
    let extraComponents = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/local/git/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]
    let missingComponents = extraComponents.filter {
      !pathComponents.contains($0)
    }

    environment["PATH"] = (pathComponents + missingComponents)
        .joined(separator: ":")
    return environment
  }
}

private final class PipeReader: @unchecked Sendable
{
  private let pipe: Pipe
  private let queue: DispatchQueue
  private let group = DispatchGroup()
  private let lock = NSRecursiveLock()
  private var data = Data()

  init(pipe: Pipe, label: String)
  {
    self.pipe = pipe
    self.queue = DispatchQueue(label: "com.helm.cli.\(label)")
  }

  func start()
  {
    group.enter()
    queue.async {
      let data = self.pipe.fileHandleForReading.readDataToEndOfFile()

      self.lock.withLock {
        self.data = data
      }
      self.group.leave()
    }
  }

  func waitForData() -> Data
  {
    group.wait()
    return lock.withLock { data }
  }
}
