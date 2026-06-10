import Foundation
import FakedMacro

@Faked
public protocol Remote: AnyObject
{
  associatedtype RefSpec: Helm.RefSpec
  
  var name: String? { get }
  var urlString: String? { get }
  var pushURLString: String? { get }
  
  @FakeDefault(exp: ".init([RefSpec]())")
  var refSpecs: AnyCollection<RefSpec> { get }
  
  func rename(_ name: String) throws
  func updateURLString(_ URLString: String?) throws
  func updatePushURLString(_ URLString: String?) throws
}

public extension Remote
{
  var url: URL? { urlString.flatMap { URL(string: $0) } }
  var pushURL: URL? { pushURLString.flatMap { URL(string: $0) } }
  
  func updateURL(_ url: URL) throws
  {
    try updateURLString(url.absoluteString)
  }
  
  func updatePushURL(_ url: URL) throws
  {
    try updatePushURLString(url.absoluteString)
  }
}

public final class GitRemote: Remote
{
  let remote: OpaquePointer
  
  public var name: String?
  {
    guard let name = git_remote_name(remote)
    else { return nil }
    
    return String(cString: name)
  }

  public var urlString: String?
  {
    guard let url = git_remote_url(remote)
    else { return nil }
    
    return String(cString: url)
  }
  
  public var pushURLString: String?
  {
    guard let url = git_remote_pushurl(remote)
    else { return nil }
    
    return String(cString: url)
  }
  
  public var refSpecs: AnyCollection<GitRefSpec>
  { AnyCollection(RefSpecCollection(remote: self)) }
  
  public init?(name: String, repository: OpaquePointer)
  {
    guard let remote = try? OpaquePointer.from({
        git_remote_lookup(&$0, repository, name) })
    else { return nil }
    
    self.remote = remote
  }
  
  public init?(url: URL)
  {
    guard let remote = try? OpaquePointer.from({
      git_remote_create_detached(&$0, url.absoluteString)
    })
    else { return nil }
    
    self.remote = remote
  }

  deinit
  {
    git_remote_free(remote)
  }

  public func rename(_ name: String) throws
  {
    guard let oldName = git_remote_name(remote),
          let owner = git_remote_owner(remote)
    else { throw RepoError.unexpected }
    
    let problems = UnsafeMutablePointer<git_strarray>.allocate(capacity: 1)
    defer {
      problems.deallocate()
    }
    
    problems.pointee = git_strarray()
    
    let result = git_remote_rename(problems, owner, oldName, name)
    let resultCode = git_error_code(rawValue: result)
    
    defer {
      git_strarray_free(problems)
    }
    switch resultCode {
      case GIT_EINVALIDSPEC:
        throw RepoError.invalidName(name)
      case GIT_EEXISTS:
        throw RepoError.duplicateName
      case GIT_OK:
        break
      default:
        throw RepoError(gitCode: resultCode)
    }
  }
  
  public func updateURLString(_ URLString: String?) throws
  {
    guard let name = git_remote_name(remote),
          let owner = git_remote_owner(remote)
    else { throw RepoError.unexpected }
    let result = git_remote_set_url(owner, name, URLString)
    
    if result == GIT_EINVALIDSPEC.rawValue {
      throw RepoError.invalidName(URLString ?? "")
    }
    else {
      try RepoError.throwIfGitError(result)
    }
  }
  
  public func updatePushURLString(_ URLString: String?) throws
  {
    guard let name = git_remote_name(remote),
          let owner = git_remote_owner(remote)
    else { throw RepoError.unexpected }
    let result = git_remote_set_pushurl(owner, name, URLString)
    
    if result == GIT_EINVALIDSPEC.rawValue {
      throw RepoError.invalidName(URLString ?? "")
    }
    else {
      try RepoError.throwIfGitError(result)
    }
  }
  
}

extension GitRemote
{
  struct RefSpecCollection: Collection
  {
    let remote: GitRemote

    var count: Int { git_remote_refspec_count(remote.remote) }
    
    func makeIterator() -> RefSpecIterator
    {
      return RefSpecIterator(remote: remote)
    }
    
    subscript(position: Int) -> GitRefSpec
    {
      return .init(refSpec: git_remote_get_refspec(remote.remote, position))
    }
    
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    
    public func index(after i: Int) -> Int
    {
      return i + 1
    }
  }
  
  public struct RefSpecIterator: IteratorProtocol
  {
    var index: Int
    let remote: GitRemote
    
    init(remote: GitRemote)
    {
      self.index = 0
      self.remote = remote
    }
    
    mutating public func next() -> GitRefSpec?
    {
      guard index < git_remote_refspec_count(remote.remote)
      else { return nil }
      
      defer {
        index += 1
      }
      return .init(refSpec: git_remote_get_refspec(remote.remote, index))
    }
  }
}
