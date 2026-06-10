import Foundation

/// Wrapper for FSEventStream.
public class FileEventStream
{
  var stream: FSEventStreamRef!
  private let path: String
  let eventCallback: ([String]) -> Void
  
  static let rescanFlags =
      UInt32(kFSEventStreamEventFlagMustScanSubDirs) |
      UInt32(kFSEventStreamEventFlagUserDropped) |
      UInt32(kFSEventStreamEventFlagKernelDropped)
  
  public var latestEventID: FSEventStreamEventId
  { FSEventStreamGetLatestEventId(stream) }
  
  /// Constructor
  /// - parameter path: The root path to watch.
  /// - parameter excludePaths: FSEvents allows up to 8 ignored paths.
  /// - parameter queue: The dispatch queue for the callback.
  /// - parameter callback: Called with a list of changed paths. An empty list
  /// means the root directory should be re-scanned.
  public init?(path: String,
               excludePaths: [String],
               queue: DispatchQueue,
               latency: CFTimeInterval = 0.5,
               callback: @escaping ([String]) -> Void)
  {
    self.path = path
    self.eventCallback = callback
    repoLogger.publicInfo("""
        fsevents create path=\(path) excludes=\(excludePaths.joined(separator: ","))
        """)
    
    let unsafeSelf = UnsafeMutableRawPointer(
        Unmanaged.passUnretained(self).toOpaque())
    // Must be var because it will be passed by reference
    var context = FSEventStreamContext(version: 0,
                                       info: unsafeSelf,
                                       retain: nil,
                                       release: nil,
                                       copyDescription: nil)
    let callback: FSEventStreamCallback = {
      (_, userData, eventCount, paths, flags, _) in
      guard let cfPaths = unsafeBitCast(paths, to: NSArray.self) as? [String]
      else { return }
      let contextSelf = unsafeBitCast(userData, to: FileEventStream.self)
      
      for index in 0..<eventCount
          where (flags[index] & FileEventStream.rescanFlags) != 0 {
        repoLogger.publicError("""
            fsevents rescanRequired path=\(contextSelf.path) \
            flag=\(flags[index])
            """)
        contextSelf.eventCallback([])
        return
      }
      
      repoLogger.publicDebug("""
          fsevents event path=\(contextSelf.path) count=\(eventCount)
          """)
      contextSelf.eventCallback(cfPaths)
    }
    
    self.stream = FSEventStreamCreate(
        kCFAllocatorDefault, callback,
        &context, [path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
        UInt32(kFSEventStreamCreateFlagUseCFTypes |
               kFSEventStreamCreateFlagNoDefer |
               kFSEventStreamCreateFlagFileEvents))
    if self.stream == nil {
      repoLogger.publicError("fsevents create failed path=\(path)")
      return nil
    }
    
    if !excludePaths.isEmpty {
      FSEventStreamSetExclusionPaths(self.stream, excludePaths as CFArray)
    }
    FSEventStreamSetDispatchQueue(self.stream, queue)
    FSEventStreamStart(self.stream)
    repoLogger.publicInfo("fsevents start path=\(path)")
  }
  
  deinit
  {
    if stream != nil {
      stop()
    }
  }
  
  public func stop()
  {
    guard stream != nil
    else { return }
    
    repoLogger.publicInfo("fsevents stop path=\(self.path)")
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    stream = nil
  }
}
