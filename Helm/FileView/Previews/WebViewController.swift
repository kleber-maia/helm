import Cocoa
import Combine
import WebKit

class WebViewController: NSViewController
{
  @IBOutlet weak var webView: WKWebView!
  var savedTabWidth: UInt = Default.tabWidth
  var savedWrapping: TextWrapping?
  private var userContentController: ControllerMessageHandler = .init()
  private(set) var editorReady = false
  private var pageRequested = false
  /// Set when the web content process terminated and the page is being
  /// reloaded, so `editorDidRecover()` fires once the fresh page is ready.
  private var recovering = false
  var pendingCalls: [() -> Void] = []
  /// Tail of the JavaScript render queue. CodeMirror loading is asynchronous
  /// (language extensions may be loaded on demand), so starting multiple
  /// calls independently lets them finish out of order and corrupt the
  /// mounted editor state.
  private var javaScriptTail: Task<Void, Never>?

  var defaults: UserDefaults = .helm

  let controllerHandlerName = "controller"

  enum Default
  {
    static var tabWidth: UInt
    { UInt(UserDefaults.helm.tabWidth) }
  }

  static let baseURL = Bundle.main.url(forResource: "html",
                                        withExtension: nil)!

  override func awakeFromNib()
  {
    userContentController.controller = self
    webView.configuration.userContentController
           .add(userContentController, name: controllerHandlerName)
    webView.navigationDelegate = self
#if DEBUG
    webView.configuration.preferences
           .setValue(true, forKey: "developerExtrasEnabled")
#endif
  }

  func ensureEditorLoaded()
  {
    guard !pageRequested
    else { return }

    guard let url = Bundle.main.url(forResource: "editor",
                                     withExtension: "html",
                                     subdirectory: "html")
    else { return }

    pageRequested = true
    webView.loadFileURL(url, allowingReadAccessTo: Self.baseURL)
  }

  /// Evaluates a JS string when the editor is ready.
  func evaluateJS(_ js: String)
  {
    callJS(js)
  }

  /// Calls an async JS function with named arguments when the editor
  /// is ready. Safer than string interpolation for large payloads.
  func callJS(_ script: String,
              arguments: [String: Any] = [:],
              when shouldRun: (() -> Bool)? = nil,
              completion: ((Bool) -> Void)? = nil)
  {
    guard pageRequested
    else { return }

    if editorReady {
      enqueueJS(script, arguments: arguments,
                when: shouldRun, completion: completion)
    }
    else {
      pendingCalls.append { [weak self] in
        guard let self else { return }
        self.enqueueJS(script, arguments: arguments,
                       when: shouldRun, completion: completion)
      }
    }
  }

  private func enqueueJS(
      _ script: String,
      arguments: [String: Any],
      when shouldRun: (() -> Bool)?,
      completion: ((Bool) -> Void)?)
  {
    let previous = javaScriptTail

    javaScriptTail = Task { @MainActor in
      await previous?.value

      guard !Task.isCancelled,
            shouldRun?() ?? true
      else {
        completion?(false)
        return
      }

      do {
        _ = try await webView.callAsyncJavaScript(
            script, arguments: arguments, contentWorld: .page)
        completion?(true)
      }
      catch {
        repoLogger.publicError("""
            editor JavaScript failed error=\(String(describing: error))
            """)
        completion?(false)
      }
    }
  }

  private func flushPendingCalls()
  {
    let calls = pendingCalls
    pendingCalls = []

    for call in calls {
      call()
    }
  }

  func wrappingWidthAdjustment() -> Int
  {
    return 0
  }

  nonisolated func webMessage(_ params: [String: Any])
  {
    guard let action = params["action"] as? String
    else { return }

    if action == "pageReady" {
      DispatchQueue.main.async {
        [self] in
        editorReady = true
        tabWidth = savedTabWidth
        wrapping = savedWrapping ?? defaults.wrapping
        flushPendingCalls()
        if recovering {
          recovering = false
          editorDidRecover()
        }
      }
      return
    }

    webMessage(action: action,
               sha: (params["sha"] as? String).flatMap { SHA($0) },
               index: params["index"] as? Int)
  }

  nonisolated func webMessage(action: String, sha: SHA?,
                               index: Int?)
  {
    // override
  }

  /// Called after the editor page has reloaded following a web content
  /// process crash. Subclasses override this to re-render their current
  /// content, which was lost when the process died.
  @objc dynamic func editorDidRecover()
  {
    // override
  }

  func setTheme(light: String?, dark: String?)
  {
    let lightArg = light.map { "'\($0)'" } ?? "null"
    let darkArg = dark.map { "'\($0)'" } ?? "null"

    evaluateJS("HelmEditor.setTheme(\(lightArg), \(darkArg))")
  }

  class ControllerMessageHandler: NSObject, WKScriptMessageHandler
  {
    weak var controller: WebViewController?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage)
    {
      guard let params = message.body as? [String: Any]
      else { return }

      controller?.webMessage(params)
    }
  }
}

extension WebViewController: TabWidthVariable
{
  var tabWidth: UInt
  {
    get
    { savedTabWidth }
    set
    {
      savedTabWidth = newValue
      guard editorReady else { return }
      evaluateJS("HelmEditor.setTabWidth(\(newValue))")
    }
  }
}

extension WebViewController: WrappingVariable
{
  public var wrapping: TextWrapping
  {
    get
    { savedWrapping ?? .windowWidth }
    set
    {
      savedWrapping = newValue
      guard editorReady else { return }

      let jsMode: String

      switch newValue {
        case .columns(let columns):
          jsMode = "'\(columns + wrappingWidthAdjustment())'"
        case .windowWidth:
          jsMode = "'window'"
        default:
          jsMode = "'none'"
      }
      evaluateJS("HelmEditor.setWrapping(\(jsMode))")
    }
  }
}

extension WebViewController: WKNavigationDelegate
{
  nonisolated
  func webView(_ webView: WKWebView,
               didFinish navigation: WKNavigation!)
  {
    DispatchQueue.main.async {
      if let scrollView = webView.enclosingScrollView {
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
      }
    }
  }

  /// The web content process can crash independently of the app (memory
  /// pressure, WebKit faults). When it does, the editor page is gone and
  /// the view is blank. Without this handler the page is never reloaded:
  /// `editorReady` stays true, so later `evaluateJS`/`callJS` calls run
  /// against a dead page and silently do nothing, leaving the diff/file
  /// preview permanently empty until the app is relaunched. Reset state,
  /// reload the page, and let subclasses re-render once it is ready.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView)
  {
    repoLogger.publicError("""
        editor web content process terminated; reloading editor page
        """)
    editorReady = false
    pageRequested = false
    pendingCalls = []
    javaScriptTail?.cancel()
    javaScriptTail = nil
    recovering = true
    ensureEditorLoaded()
  }
}
