import Foundation

/// The getter, setter, and in-place mutations are wrapped in a mutex.
///
/// In-place mutations such as `value.field = x` or `value.mutatingCall()`
/// hold the mutex for the whole read-modify-write, so concurrent updates to
/// different fields of a struct can't overwrite each other.
@propertyWrapper
public struct MutexProtected<T>
{
  let mutex = NSRecursiveLock()
  var value: T

  public var wrappedValue: T
  {
    get { mutex.withLock { value } }
    set { mutex.withLock { value = newValue } }
    // Without this, a member assignment is a separate locked get and set.
    // Another thread's write between the two would be lost when the stale
    // copy is written back.
    _modify
    {
      mutex.lock()
      defer { mutex.unlock() }
      yield &value
    }
  }

  /// Provides access to the mutex, which is recursive, so it may be useful to
  /// lock it for multiple operations.
  public var projectedValue: NSRecursiveLock { mutex }

  public init(wrappedValue: T)
  {
    self.value = wrappedValue
  }
}
