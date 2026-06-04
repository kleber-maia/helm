import Cocoa
import Combine

/// View controller for the file list and detail view.
final class FileViewController: NSViewController, RepositoryWindowViewController
{
  typealias Repository = BasicRepository & CommitStorage & CommitReferencing &
                         FileContents & FileStaging & FileStatusDetection &
                         RepoConfiguring

  /// Preview tab identifiers
  enum TabID
  {
    static let diff = "diff"
    static let text = "text"

    static let allIDs = [ diff, text ]
  }
  
  enum MainTab
  {
    static let summary = "summary"
    static let files = "files"
  }

  enum HeaderTab
  {
    static let display = "display"
    static let entry = "entry"
  }

  enum FileListTab
  {
    static let commit = "commit"
    static let staging = "staging"
  }

  var mainTabSelector: NSSegmentedControl!
  var summaryTabView: NSView!
  var filesTabView: NSView!
  @IBOutlet weak var fileSplitView: NSSplitView!
  @IBOutlet weak var fileListSplitView: NSSplitView!  // retained for XIB compat
  @IBOutlet weak var fileListTabView: NSTabView!
  @IBOutlet weak var headerTabView: NSTabView!
  @IBOutlet weak var previewPath: NSPathControl!
  @IBOutlet weak var diffController: FileDiffController!
  @IBOutlet weak var previewSegmentControl: NSSegmentedControl!
  var commitHeader: CommitHeaderHostingView!
  var commitEntryController: CommitEntryController!

  /// Overlay shown when the review panel has no pending changes.
  private var emptyOverlay: NSView?

  /// When `true`, the Files tab is selected on first display instead of Summary.
  var startsOnFilesTab = false

  /// When `true`, this instance is the standalone review panel and only
  /// processes `StagingSelection` events. When `false` (history panel),
  /// staging events are ignored so the two panels never share selection state.
  var isReviewPanel = false

  var contentController: FileContentLoading!
  
  var fileWatcher: FileEventStream?
  var indexTimer: Timer?
  var sinks: [AnyCancellable] = []
  
  var contentControllers: [FileContentLoading]
  { [diffController] }
  
  var inStagingView: Bool
  { repoSelection is StagedUnstagedSelection }
  
  /// True if the repository selection supports committing (ie the Staging item)
  var selectionCanCommit: Bool
  { repoSelection is StagingSelection }
  
  /// True when the staged file list is showing (two file lists instead of one)
  var showingStaged: Bool
  {
    get
    {
      guard let id = fileListTabView.selectedTabViewItem?.identifier as? String
      else { return false }
      
      return id == FileListTab.staging
    }
    set
    {
      fileListTabView.selectTabViewItem(withIdentifier: newValue ?
          FileListTab.staging : FileListTab.commit)
      if newValue {
        let showAction = repoUIController?.selection is StagingSelection

        reviewListController.setActionColumnShown(showAction)
        reviewListController.setWorkspaceControlsShown(showAction)
      }
    }
  }
  
  /// True when the commit message entry field is showing
  var isCommitting: Bool
  {
    get
    {
      guard let id = headerTabView.selectedTabViewItem?.identifier as? String
      else { return false }
      
      return id == HeaderTab.entry
    }
    set
    {
      headerTabView.selectTabViewItem(at: newValue ? 1 : 0)
    }
  }
  
  let commitListController = CommitFileListController(isWorkspace: false)
  let reviewListController = ReviewFileListController()
  let allListControllers: [FileListController]
  
  var mainFileList: NSOutlineView
  {
    if showingStaged {
      return reviewListController.outlineView
    }
    else {
      return commitListController.outlineView
    }
  }
  /// The file list (eg Staged or Workspace) that last had user focus
  weak var activeFileList: NSOutlineView!
  var activeFileListController: FileListController
  { activeFileList.delegate as! FileListController }
  var selectedChange: FileChange?
  { activeFileListController.selectedChange }
  var selectedChanges: [FileChange]
  { activeFileListController.selectedChanges }
  
  weak var repo: (any Repository)?
  {
    didSet
    {
      commitHeader.repository = repo
    }
  }
  
  override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?)
  {
    self.allListControllers = [commitListController,
                               reviewListController]

    super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

    for controller in allListControllers {
      addChild(controller)
    }
  }
  
  required init?(coder: NSCoder)
  {
    fatalError("init(coder:) has not been implemented")
  }
  
  deinit
  {
    indexTimer?.invalidate()
  }

  override func awakeFromNib()
  {
    commitHeader = .init(rootView: CommitHeader())
    commitHeader.selectParent = {
      [weak self] oid in
      self?.repoUIController?.select(oid: oid)
    }

    let scrollView = NSScrollView()

    scrollView.documentView = commitHeader
    scrollView.hasVerticalScroller = true
    headerTabView.tabViewItem(at: 0).view = commitHeader
    previewSegmentControl.prefersCompactControlSizeMetrics = true
  }
  
  func finishLoad(repository: any Repository)
  {
    repo = repository
    diffController.repo = repository

    guard let controller = repoUIController
    else { return }

    sinks.append(contentsOf: [
      controller.repoController.indexPublisher
        .sinkOnMainQueue {
          [weak self] in
          self?.indexChanged()
        },
      controller.selectionPublisher
        .sink {
          [weak self] _ in
          self?.selectedModelChanged()
        },
    ])

    commitEntryController.configure(repository: repository,
                                    config: repository.config)
    
    let commitTabItem = fileListTabView.tabViewItem(at: 0)

    _ = commitListController.view
    commitTabItem.viewController = commitListController

    let stagingTabItem = fileListTabView.tabViewItem(at: 1)

    _ = reviewListController.view
    stagingTabItem.viewController = reviewListController

    activeFileList = commitListController.outlineView

    let center = NotificationCenter.default

    sinks.append(contentsOf: allListControllers.map {
      (listController) in
      center.publisher(for: NSOutlineView.selectionDidChangeNotification,
                       object: listController.outlineView)
        .sink {
          [weak self] note in
          guard let self = self,
                let listController = (note.object as? NSOutlineView)?.delegate
                                     as? FileListController
          else { return }
          let isActive = self.showingStaged
              ? listController === self.reviewListController
              : listController === self.commitListController
          guard isActive else { return }
          self.activeFileList = listController.outlineView
          self.refreshPreview()
        }
    })
    if let window = view.window {
      sinks.append(window.publisher(for: \.firstResponder).sinkOnMainQueue {
        [weak self] _ in
        self?.updatePreviewForActiveList()
      })
    }
  }
  
  override func loadView()
  {
    super.loadView()

    contentController = diffController

    commitEntryController = CommitEntryController(
        nibName: "CommitEntryController", bundle: nil)
    if let repo = repo {
      commitEntryController.configure(repository: repo, config: repo.config)
    }

    headerTabView.tabViewItems[1].view = commitEntryController.view
    previewPath.pathItems = []
    diffController.stagingDelegate = self
    diffController.ensureEditorLoaded()
    installThemePicker()
    stylePreviewHeader()
    setupTabInterface()
  }

  // MARK: - Theme picker

  struct ThemeInfo
  {
    let id: String
    let name: String
    let isDark: Bool
  }

  static let themes: [ThemeInfo] = [
    .init(id: "xcode-light",     name: "Xcode Light",      isDark: false),
    .init(id: "github-light",    name: "GitHub Light",      isDark: false),
    .init(id: "vscode-light",    name: "VS Code Light",     isDark: false),
    .init(id: "solarized-light", name: "Solarized Light",   isDark: false),
    .init(id: "tokyo-night-day", name: "Tokyo Night Day",   isDark: false),
    .init(id: "xcode-dark",      name: "Xcode Dark",        isDark: true),
    .init(id: "github-dark",     name: "GitHub Dark",       isDark: true),
    .init(id: "vscode-dark",     name: "VS Code Dark",      isDark: true),
    .init(id: "solarized-dark",  name: "Solarized Dark",    isDark: true),
    .init(id: "tokyo-night",     name: "Tokyo Night",       isDark: true),
    .init(id: "nord",            name: "Nord",              isDark: true),
    .init(id: "dracula",         name: "Dracula",           isDark: true),
    .init(id: "sublime",         name: "Sublime",           isDark: true),
    .init(id: "monokai",         name: "Monokai",           isDark: true),
    .init(id: "atomone",         name: "Atom One",          isDark: true),
  ]

  private func installThemePicker()
  {
    guard let contentPane = previewSegmentControl.superview
    else { return }

    let popup = NSPopUpButton(frame: .zero, pullsDown: true)

    popup.translatesAutoresizingMaskIntoConstraints = false
    popup.bezelStyle = .accessoryBarAction
    popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    popup.isBordered = false

    popup.addItem(withTitle: "Theme")
    popup.item(at: 0)?.image = NSImage(
        systemSymbolName: "paintbrush",
        accessibilityDescription: "Theme")

    let lightHeader = NSMenuItem.sectionHeader(title: "Light")

    popup.menu?.addItem(lightHeader)
    for theme in Self.themes where !theme.isDark {
      let item = NSMenuItem(title: theme.name,
                            action: #selector(themeSelected(_:)),
                            keyEquivalent: "")
      item.target = self
      item.representedObject = theme.id
      popup.menu?.addItem(item)
    }

    let darkHeader = NSMenuItem.sectionHeader(title: "Dark")

    popup.menu?.addItem(darkHeader)
    for theme in Self.themes where theme.isDark {
      let item = NSMenuItem(title: theme.name,
                            action: #selector(themeSelected(_:)),
                            keyEquivalent: "")
      item.target = self
      item.representedObject = theme.id
      popup.menu?.addItem(item)
    }

    contentPane.addSubview(popup)
    NSLayoutConstraint.activate([
      popup.trailingAnchor.constraint(
          equalTo: contentPane.trailingAnchor, constant: -4),
      popup.centerYAnchor.constraint(
          equalTo: previewSegmentControl.centerYAnchor),
    ])

    // Apply saved theme on load
    let defaults = UserDefaults.helm
    let light = defaults.editorLightTheme
    let dark = defaults.editorDarkTheme

    diffController.setTheme(light: light, dark: dark)
  }

  @objc func themeSelected(_ sender: NSMenuItem)
  {
    guard let themeId = sender.representedObject as? String,
          let theme = Self.themes.first(where: { $0.id == themeId })
    else { return }

    let defaults = UserDefaults.helm

    if theme.isDark {
      defaults.editorDarkTheme = themeId
      diffController.setTheme(light: nil, dark: themeId)
    }
    else {
      defaults.editorLightTheme = themeId
      diffController.setTheme(light: themeId, dark: nil)
    }
  }

  func validateThemeMenuItem(_ menuItem: NSMenuItem) -> Bool
  {
    guard let themeId = menuItem.representedObject as? String,
          let theme = Self.themes.first(where: { $0.id == themeId })
    else { return true }

    let defaults = UserDefaults.helm
    let currentId = theme.isDark
        ? defaults.editorDarkTheme
        : defaults.editorLightTheme

    menuItem.state = (themeId == currentId) ? .on : .off
    return true
  }

  /// Styles the preview header with thin separator lines to match
  /// the History table header look.
  func stylePreviewHeader()
  {
    guard let contentPane = previewSegmentControl.superview
    else { return }

    for subview in contentPane.subviews {
      guard let button = subview as? NSButton,
            button.identifier?.rawValue == "previewHeader"
      else { continue }

      button.isTransparent = true
      button.addBorderLines()
      break
    }
  }

  func setupTabInterface()
  {
    headerTabView.removeFromSuperview()
    fileSplitView.removeFromSuperview()

    let selector = NSSegmentedControl(labels: ["Summary", "Files"],
                                      trackingMode: .selectOne,
                                      target: self,
                                      action: #selector(mainTabChanged(_:)))
    selector.selectedSegment = startsOnFilesTab ? 1 : 0
    selector.translatesAutoresizingMaskIntoConstraints = false
    selector.setContentHuggingPriority(.defaultHigh, for: .vertical)
    mainTabSelector = selector

    let summaryContainer = NSView()
    summaryContainer.translatesAutoresizingMaskIntoConstraints = false
    headerTabView.translatesAutoresizingMaskIntoConstraints = false
    summaryContainer.addSubview(headerTabView)
    NSLayoutConstraint.activate([
      headerTabView.topAnchor.constraint(equalTo: summaryContainer.topAnchor),
      headerTabView.bottomAnchor.constraint(equalTo: summaryContainer.bottomAnchor),
      headerTabView.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor),
      headerTabView.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor),
    ])
    summaryContainer.isHidden = startsOnFilesTab
    summaryTabView = summaryContainer

    let filesContainer = NSView()
    filesContainer.translatesAutoresizingMaskIntoConstraints = false
    fileSplitView.translatesAutoresizingMaskIntoConstraints = false
    filesContainer.addSubview(fileSplitView)
    NSLayoutConstraint.activate([
      fileSplitView.topAnchor.constraint(equalTo: filesContainer.topAnchor),
      fileSplitView.bottomAnchor.constraint(equalTo: filesContainer.bottomAnchor),
      fileSplitView.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor),
      fileSplitView.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor),
    ])
    filesContainer.isHidden = !startsOnFilesTab
    filesTabView = filesContainer

    // Replace the NIB's NSSplitView root with a plain NSView so the
    // NSSplitViewController that hosts FileViewController sees a regular view
    // rather than an empty NSSplitView (which would collapse to zero size).
    // TAMIC must be false so NSSplitViewController's own Auto Layout constraints
    // govern position/size without conflicting with autoresizing-mask constraints.
    let rootView = NSView()
    // Inherit the NIB root view’s frame so NSSplitViewController has a
    // non-zero initial size to work with for the initial layout.
    rootView.frame = view.frame
    rootView.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(selector)
    rootView.addSubview(summaryContainer)
    rootView.addSubview(filesContainer)
    NSLayoutConstraint.activate([
      selector.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor,
                                    constant: 4),
      selector.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      summaryContainer.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 4),
      summaryContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      summaryContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      summaryContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      filesContainer.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 4),
      filesContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      filesContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      filesContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
    ])
    view = rootView

    if isReviewPanel {
      installEmptyOverlay()
    }
  }

  @objc func mainTabChanged(_ sender: NSSegmentedControl)
  {
    summaryTabView.isHidden = sender.selectedSegment != 0
    filesTabView.isHidden = sender.selectedSegment != 1

    if sender.selectedSegment == 1 {
      // The fileSplitView was hidden while on the Summary tab,
      // so the settle cycle couldn't apply the position.
      // Force layout and apply now.
      view.layoutSubtreeIfNeeded()
      applyFileListPosition()
    }
  }

  /// Creates and installs the empty-state overlay for the review panel.
  func installEmptyOverlay()
  {
    let overlay = NSView()

    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.wantsLayer = true

    let icon = NSImageView()

    icon.translatesAutoresizingMaskIntoConstraints = false
    let appIcon = NSWorkspace.shared.icon(
        forFile: Bundle.main.bundlePath)
    appIcon.isTemplate = false
    icon.image = appIcon
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.appearance = NSAppearance(named: .aqua)
    icon.setContentHuggingPriority(.defaultLow, for: .horizontal)
    icon.setContentHuggingPriority(.defaultLow, for: .vertical)

    let label = NSTextField(
        labelWithString: "Steady as she goes — nothing to commit, Captain.")

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .tertiaryLabelColor
    label.alignment = .center

    let stack = NSStackView(views: [icon, label])

    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 16

    overlay.addSubview(stack)

    let iconSize: CGFloat = 256

    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: iconSize),
      icon.heightAnchor.constraint(equalToConstant: iconSize),
      stack.centerXAnchor.constraint(
          equalTo: overlay.centerXAnchor),
      stack.centerYAnchor.constraint(
          equalTo: overlay.centerYAnchor),
    ])

    view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.topAnchor.constraint(equalTo: view.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      overlay.leadingAnchor.constraint(
          equalTo: view.leadingAnchor),
      overlay.trailingAnchor.constraint(
          equalTo: view.trailingAnchor),
    ])

    overlay.isHidden = true
    emptyOverlay = overlay
  }

  func updateEmptyOverlay(isEmpty: Bool)
  {
    guard isReviewPanel, let overlay = emptyOverlay
    else { return }

    let wasHidden = overlay.isHidden

    overlay.isHidden = !isEmpty
    mainTabSelector?.isHidden = isEmpty
    summaryTabView?.isHidden = isEmpty
        || mainTabSelector?.selectedSegment != 0
    filesTabView?.isHidden = isEmpty
        || mainTabSelector?.selectedSegment != 1
    if !isEmpty && wasHidden {
      // Restore tabs to reflect the current segment
      mainTabChanged(mainTabSelector)
    }
  }

  private var listControllersInitialized = false

  override func viewWillAppear()
  {
    super.viewWillAppear()
    initializeListControllers()
  }

  override func viewDidAppear()
  {
    super.viewDidAppear()
    applyFileListPosition()
  }

  /// Sets up list-controller data sources and subscriptions.  Safe to
  /// call more than once — subsequent calls are no-ops.
  func initializeListControllers()
  {
    guard !listControllersInitialized,
          let controller = repoUIController
    else { return }
    listControllersInitialized = true

    reviewListController.stagingDataSource.isReviewPanel = isReviewPanel

    if isReviewPanel {
      reviewListController.stagingDataSource.onReloadComplete = {
        [weak self] isEmpty in
        self?.updateEmptyOverlay(isEmpty: isEmpty)
      }
    }

    for listController in allListControllers {
      listController.fileTreeDataSource.isReviewPanel = isReviewPanel
      listController.finishLoad(controller: controller)
    }
  }
  
  func restoreSplit() {}

  func saveSplit() {}
  
  func updatePreviewForActiveList()
  {
    if let newActive = self.view.window?.firstResponder as? NSOutlineView,
       newActive != self.activeFileList &&
       self.allListControllers.contains(where: { $0.outlineView === newActive }) {
      activeFileList.deselectAll(self)
      activeFileList = newActive
      refreshPreview()
    }
  }
  
  func indexChanged()
  {
    // Only the review panel reacts to index changes (staging area changes).
    guard isReviewPanel
    else { return }

    // Reading the index too soon can yield incorrect results.
    let indexDelay: TimeInterval = 0.125

    if let timer = indexTimer {
      timer.fireDate = Date(timeIntervalSinceNow: indexDelay)
    }
    else {
      // TODO: use a publisher with debounce
      indexTimer = Timer.mainScheduledTimer(withTimeInterval: indexDelay,
                                            repeats: false) {
        [weak self] (_) in
        self?.indexTimer = nil
        self?.reload()
        self?.refreshPreview()
      }
    }

    // Ideally, check to see if the selected file has changed
    if selectionCanCommit {
      loadSelectedPreview(force: true)
    }
  }
  
  func reload()
  {
    activeFileList.reloadData()
  }
  
  func refreshPreview()
  {
    DispatchQueue.main.async {
      self.loadSelectedPreview(force: true)
    }
  }
  
  func updatePreviewPath(_ path: String, isFolder: Bool)
  {
    let components = (path as NSString).pathComponents
    let items = components.enumerated().map {
      (index, component) -> NSPathControlItem in
      let workspace = NSWorkspace.shared
      let item = NSPathControlItem()

      item.title = component
      item.image = !isFolder && (index == components.count - 1)
          ? workspace.icon(for: .fromExtension(component.pathExtension))
          : NSImage(named: NSImage.folderName)
      
      return item
    }
    
    previewPath.pathItems = items
  }
  
  func selectedModelChanged()
  {
    guard let controller = repoUIController,
          let newModel = controller.selection
    else { return }
    // Each panel only handles its own selection type: review handles staging,
    // history handles everything else. This prevents shared `activeFileList`
    // state corruption between the two FileViewController instances.
    guard (newModel is StagingSelection) == isReviewPanel
    else { return }

    for controller in allListControllers {
      controller.repoSelectionChanged()
    }
    showingStaged = newModel is StagedUnstagedSelection
    isCommitting = newModel is StagingSelection
    // Keep activeFileList consistent with whichever tab is now showing so
    // that refreshPreview() below uses the right list immediately, before any
    // async data-source reload notifications arrive.
    activeFileList = showingStaged ? reviewListController.outlineView
                                   : commitListController.outlineView
    if let commit = newModel.target.oid.flatMap({ repo?.commit(forOID: $0) }) {
      commitHeader.commit = commit
    }
    clearPreviews()
    refreshPreview()
    DispatchQueue.main.async { // wait for the file lists to refresh
      self.ensureFileSelection()
    }
  }
  
  func ensureFileSelection()
  {
    let outlineViw = mainFileList
    
    if (outlineViw.selectedRow == -1) && (outlineViw.numberOfRows > 0) {
      outlineViw.selectRowIndexes(IndexSet(integer: 0),
                                  byExtendingSelection: false)
    }
  }
  
  func loadSelectedPreview(force: Bool = false)
  {
    guard !contentController.isLoaded || force
    else { return }
    
    let changes = selectedChanges
    guard !changes.isEmpty,
          let repo = repo,
          let index = activeFileList.selectedRowIndexes.first,
          let selectedItem = activeFileList.item(atRow: index),
          let controller = repoUIController,
          let repoSelection = controller.selection
    else {
      clearPreviews()
      return
    }
    let selectedChange = changes.first!
    let staging = repoSelection is StagingSelection
    let stagingType: StagingType
    if staging {
      stagingType = reviewListController.isSelectedItemStaged()
          ? .index : .workspace
    }
    else {
      stagingType = .none
    }

    if changes.count == 1 {
      updatePreviewPath(selectedChange.gitPath,
                        isFolder: activeFileList.isExpandable(selectedItem))
    }
    else {
      DispatchQueue.main.async {
        let item = NSPathControlItem()
        
        item.titleString = .multipleSelection
        self.previewPath.pathItems = [item]
      }
    }
    let selection = changes.map {
      FileSelection(repoSelection: repoSelection, path: $0.gitPath,
                    staging: stagingType)
    }
    
    Task {
      @MainActor in
      self.contentController.load(selection: selection)
    }

    let fullPath = repo.repoURL.path.appending(
                      pathComponent: selectedChange.gitPath)
    
    fileWatcher = inStagingView
        ? FileEventStream(path: fullPath,
                          excludePaths: [],
                          queue: .main,
                          latency: 0.5) {
            [weak self] (_) in self?.loadSelectedPreview(force: true)
          }
        : nil
  }
  
  func clearPreviews()
  {
    DispatchQueue.main.async {
      self.contentControllers.forEach { $0.clear() }
      self.previewPath.pathItems = []
    }
  }
  
  func clear()
  {
    contentController.clear()
    previewPath.pathItems = []
  }
  
  func revert(path: String)
  {
    guard let repo = repo,
          let window = view.window
    else { return }

    let confirmAlert = NSAlert()
    let status = try? repo.unstagedStatus(for: path)
    let name = (path as NSString).lastPathComponent
    
    confirmAlert.messageString = .confirmRevert(name)
    if status == .untracked {
      confirmAlert.informativeString = .newFileDeleted
    }
    confirmAlert.addButton(withString: .revert)
    confirmAlert.addButton(withString: .cancel)
    confirmAlert.buttons[0].hasDestructiveAction = true
    
    Task {
      if await confirmAlert.beginSheetModal(for: window) ==
          .alertFirstButtonReturn {
        do {
          try repo.revert(file: path)
        }
        catch let error as RepoError {
          let alert = NSAlert()
          
          alert.messageString = error.message
          alert.beginSheetModal(for: window, completionHandler: nil)
        }
        catch {
          let alert = NSAlert(error: error as NSError)

          await alert.beginSheetModal(for: window)
        }
      }
    }
  }

  func displayAlert(error: NSError)
  {
    guard let window = view.window
    else { return }
    let alert = NSAlert(error: error)
    
    alert.beginSheetModal(for: window)
  }
  
  func displayRepositoryAlert(error: RepoError)
  {
    guard let window = view.window
    else { return }
    let alert = NSAlert()
    
    alert.messageString = error.message
    alert.beginSheetModal(for: window)
  }
}
