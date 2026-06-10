import Foundation
import Combine

final class FileMonitor
{
  let path: String
  private var sourceMutex = NSRecursiveLock()
  var fd: CInt = -1
  var source: DispatchSourceFileSystemObject?
  let subject = PassthroughSubject<(String, UInt), Never>()
  var eventPublisher: AnyPublisher<(String, UInt), Never>
  { subject.eraseToAnyPublisher() }

  init?(path: String)
  {
    self.path = path
    repoLogger.publicInfo("fileMonitor create path=\(path)")
    
    makeSource()
    if sourceMutex.withLock({ source }) == nil {
      repoLogger.publicError("fileMonitor create failed path=\(path)")
      return nil
    }
  }
  
  func makeSource()
  {
    fd = open(path, O_EVTONLY)
    guard fd >= 0
    else {
      repoLogger.publicError("fileMonitor open failed path=\(self.path) errno=\(errno)")
      return
    }
    
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.delete, .write, .extend, .attrib, .link, .rename, .revoke],
        queue: DispatchQueue.global())
    
    source.setEventHandler {
      [weak self] in
      guard let self = self
      else { return }
      
      self.sourceMutex.lock()
      defer { self.sourceMutex.unlock() }
      
      guard let source = self.source
      else { return }

      repoLogger.publicInfo("""
          fileMonitor event path=\(self.path) flags=\(source.data.rawValue)
          """)
      self.subject.send((self.path, source.data.rawValue))
      if source.data.contains(.delete) {
        repoLogger.publicInfo("fileMonitor recreateAfterDelete path=\(self.path)")
        source.cancel()
        close(self.fd)
        self.sourceMutex.withLock {
          self.source = nil
        }
        self.makeSource()
      }
    }
    source.resume()
    sourceMutex.withLock {
      self.source = source
    }
    repoLogger.publicInfo("fileMonitor start path=\(self.path)")
  }
  
  deinit
  {
    repoLogger.publicInfo("fileMonitor stop path=\(self.path)")
    source?.cancel()
    close(fd)
  }
}
