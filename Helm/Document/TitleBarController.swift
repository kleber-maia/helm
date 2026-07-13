import Cocoa
import Combine

@MainActor
protocol TitleBarDelegate: AnyObject
{
  func goBack()
  func goForward()
  func pushSelected()
  func pullSelected()
  func stashSelected()
  func popStashSelected()
  func applyStashSelected()
  func dropStashSelected()
  func search(for text: String,
              type: HistorySearchType,
              direction: SearchDirection)
}

@MainActor
class TitleBarController: NSObject
{
  @IBOutlet weak var window: NSWindow!
  @IBOutlet weak var navButtons: NSSegmentedControl!
  @IBOutlet weak var remoteControls: NSSegmentedControl!
  @IBOutlet weak var stashButton: NSSegmentedControl!
  @IBOutlet weak var spinner: NSProgressIndicator!
  var stashMenu: NSMenu!
  var fetchMenu: NSMenu!
  var pushMenu: NSMenu!
  var pullMenu: NSMenu!
  var remoteOpsMenu: NSMenu!
  @IBOutlet var splitView: NSSplitView!

  weak var delegate: (any TitleBarDelegate)?
  
  private var sinks: [AnyCancellable] = []
  
  /// `true` when the Review (staging) panel is active.
  var reviewActive = false {
    didSet {
      if reviewActive { hideSearch() }
      updateContextualItems()
    }
  }

  var separatorItem: NSToolbarItem?
  private var stashToolbarItem: NSToolbarItem?
  
  private var newBranchToolbarItem: NSToolbarItem?
  private var customActionToolbarItem: NSToolbarItem?
  private var codingAgentUsageToolbarGroup: NSToolbarItemGroup?
  private var codingAgentToolbarItem: NSMenuToolbarItem?
  private var codexBarUsageToolbarItem: NSToolbarItem?
  private var codexBarUsageView: TerminalCodexBarStatusView?
  private var codexBarUsageRefreshTimer: Timer?
  private var codexBarUsageFetchInProgress = false
  private var codexBarUsageContext: CodexBarUsageContext?
  private var codexBarUsageFetchContext: CodexBarUsageContext?
  private var lastCodexBarUsageRefreshByContext:
      [CodexBarUsageContext: Date] = [:]
  private var lastCodexBarUsageFailureByContext:
      [CodexBarUsageContext: Date] = [:]
  private var searchToolbarItem: NSSearchToolbarItem?
  private var previousSearchItem: NSToolbarItem?
  private var nextSearchItem: NSToolbarItem?
  private var searchTypeItems: [NSMenuItem] = []
  private var searchEnabled = true
  private var searchText = ""
  private var searchType: HistorySearchType = .summary {
    didSet {
      updateSearchTypeMenuState()
      updateSearchPlaceholder()
    }
  }
  
  @objc dynamic var progressHidden: Bool
  {
    get
    { spinner.isHidden }
    set
    {
      spinner.isIndeterminate = true
      spinner.isHidden = newValue
      if newValue {
        spinner.stopAnimation(nil)
      }
      else {
        spinner.startAnimation(nil)
      }
    }
  }
  
  enum NavSegment: Int
  {
    case back, forward
  }
  
  enum RemoteSegment: Int
  {
    case pull, push
  }
  
  @MainActor
  override func awakeFromNib()
  {
    super.awakeFromNib()
    makeMenus()
  }

  private func makeMenus()
  {
    fetchMenu = NSMenu {
      NSMenuItem(.fetchAllRemotes,
                 action: #selector(HelmWindowController.fetchAllRemotes(_:)))
      NSMenuItem(.fetchCurrentUnavailable,
                 action: #selector(HelmWindowController.fetchCurrentBranch(_:)))
      NSMenuItem.separator()
        .with(identifier: HelmWindowController.RemoteMenuType.fetch.identifier)
      NSMenuItem(.fetchRemote("unknown"),
                 action: #selector(HelmWindowController.fetchRemote(_:)))
    }
    fetchMenu.setAccessibilityIdentifier(AXID.PopupMenu.fetch)
    pullMenu = NSMenu {
      NSMenuItem(.pull,
                 action: #selector(HelmWindowController.pullCurrentBranch(_:)))
    }
    pullMenu.setAccessibilityIdentifier(AXID.PopupMenu.pull)
    pushMenu = NSMenu {
      NSMenuItem(.pushNew,
                 action: #selector(HelmWindowController.push(_:)))
      NSMenuItem.separator()
        .with(identifier: HelmWindowController.RemoteMenuType.push.identifier)
      NSMenuItem(.pushToRemote,
                 action: #selector(HelmWindowController.pushToRemote(_:)))
    }
    pushMenu.setAccessibilityIdentifier(AXID.PopupMenu.push)
    stashMenu = NSMenu {
      NSMenuItem(.saveStash,
                 systemImage: "tray.and.arrow.down.fill",
                 action: #selector(HelmWindowController.stash(_:)))
      NSMenuItem.separator()
      NSMenuItem(.pop,
                 systemImage: "tray.and.arrow.up.fill",
                 action: #selector(HelmWindowController.popStash(_:)))
      NSMenuItem(.apply,
                 systemImage: "tray.and.arrow.up",
                 action: #selector(HelmWindowController.applyStash(_:)))
      NSMenuItem(.drop,
                  systemImage: "trash",
                 action: #selector(HelmWindowController.dropStash(_:)))
    }
    remoteOpsMenu = NSMenu {
      NSMenuItem(.pull,
                 systemImage: "square.and.arrow.down.fill",
                 action: #selector(HelmWindowController.pull(_:)))
      NSMenuItem(.push,
                 systemImage: "square.and.arrow.up.fill",
                 action: #selector(HelmWindowController.push(_:)))
    }
    guard let controller = window.windowController as? HelmWindowController
    else {
      assertionFailure("can't get window controller")
      return
    }
    let menus = [pullMenu, pushMenu,
                 stashMenu, remoteOpsMenu]

    for menu in menus {
      menu?.delegate = controller
    }
  }
  
  func finishSetup()
  {
    remoteOpsMenu.items[0].submenu = pullMenu
    remoteOpsMenu.items[1].submenu = pushMenu
    updateSearchControls()
  }
  
  func observe(controller: any RepositoryController)
  {
    sinks.removeAll()
    sinks.append(controller.progressPublisher
      .receive(on: DispatchQueue.main)
      .sink {
        (progress, total) in
        
        if progress < total {
          self.spinner.isIndeterminate = false
          self.spinner.startAnimation(nil)
          self.spinner.maxValue = Double(total)
          self.spinner.doubleValue = Double(progress)
          self.spinner.needsDisplay = true
        }
        else {
          self.spinner.stopAnimation(nil)
          self.spinner.isHidden = true
        }
    })

    let repositoryRefreshPublishers: [AnyPublisher<Void, Never>] = [
      controller.configPublisher,
      controller.headPublisher,
      controller.indexPublisher,
      controller.refsPublisher,
      controller.stashPublisher,
      controller.workspacePublisher.map { _ in () }.eraseToAnyPublisher(),
    ]

    sinks.append(Publishers.MergeMany(repositoryRefreshPublishers)
      .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
      .sink {
        [weak self] _ in
        self?.refreshCodexBarUsageItem()
      })
  }

  @IBAction
  func navigate(_ sender: Any?)
  {
    guard let control = sender as? NSSegmentedControl,
          let segment = NavSegment(rawValue: control.selectedSegment)
    else { return }
    
    switch segment {
      case .back:
        delegate?.goBack()
      case .forward:
        delegate?.goForward()
    }
  }
  
  @IBAction
  func remoteAction(_ sender: Any?)
  {
    guard let control = sender as? NSSegmentedControl,
          let segment = RemoteSegment(rawValue: control.selectedSegment)
    else { return }
    
    switch segment {
      case .pull:
        delegate?.pullSelected()
      case .push:
        delegate?.pushSelected()
    }
  }
  
  @IBAction
  func stash(_ sender: Any)
  {
    delegate?.stashSelected()
  }
  
  @IBAction
  func popStash(_ sender: Any)
  {
    delegate?.popStashSelected()
  }
  
  @IBAction
  func applyStash(_ sender: Any)
  {
    delegate?.applyStashSelected()
  }
  
  @IBAction
  func dropStash(_ sender: Any)
  {
    delegate?.dropStashSelected()
  }
  
  func setSearchEnabled(_ enabled: Bool)
  {
    searchEnabled = enabled
    if !enabled {
      hideSearch()
    }
    updateSearchControls()
  }

  func showSearch()
  {
    guard searchEnabled, !reviewActive
    else { return }

    searchToolbarItem?.beginSearchInteraction()
    if let item = searchToolbarItem {
      window.makeFirstResponder(item.searchField)
    }
    updateSearchControls()
  }

  func search(_ direction: SearchDirection)
  {
    guard searchEnabled
    else { return }

    guard !searchText.isEmpty
    else { return }
    delegate?.search(for: searchText,
                     type: searchType,
                     direction: direction)
  }

  func useSelectionForSearch(_ text: String)
  {
    guard let field = searchToolbarItem?.searchField,
          searchEnabled
    else { return }

    showSearch()
    searchText = text
    field.stringValue = text
    updateSearchControls()
  }

  var canShowSearch: Bool
  { searchEnabled && !reviewActive }

  var canNavigateSearch: Bool
  { searchEnabled && !searchText.isEmpty }

  /// Enables/disables stash, clean, and search items based on
  /// whether the Review panel or the History panel is active.
  private func updateContextualItems()
  {
    stashToolbarItem?.isEnabled = reviewActive
    newBranchToolbarItem?.isEnabled = !reviewActive

    let searchOK = searchEnabled && !reviewActive
    let hasQuery = !searchText.isEmpty

    searchToolbarItem?.isEnabled = searchOK
    previousSearchItem?.isEnabled = searchOK && hasQuery
    nextSearchItem?.isEnabled = searchOK && hasQuery
  }

  private func updateSearchControls()
  {
    updateContextualItems()
  }

  private func updateSearchTypeMenuState()
  {
    for (index, item) in searchTypeItems.enumerated() {
      item.state = HistorySearchType.allCases[index] == searchType ? .on : .off
    }
  }

  private func updateSearchPlaceholder()
  {
    searchToolbarItem?.searchField.placeholderString =
      "Search \(searchType.displayName.rawValue)"
  }

  private func hideSearch()
  {
    searchText = ""
    searchToolbarItem?.endSearchInteraction()
    searchToolbarItem?.searchField.stringValue = ""
    updateSearchControls()
  }

  private func makeSearchMenu() -> NSMenu
  {
    let menu = NSMenu()

    searchTypeItems = []
    menu.autoenablesItems = false
    for (index, type) in HistorySearchType.allCases.enumerated() {
      let item = NSMenuItem(title: type.displayName.rawValue,
                            action: #selector(selectSearchType(_:)),
                            keyEquivalent: "")

      item.target = self
      item.tag = index
      menu.addItem(item)
      searchTypeItems.append(item)
    }
    updateSearchTypeMenuState()
    return menu
  }

  @IBAction
  private func runSearch(_ sender: NSSearchField)
  {
    searchText = sender.stringValue
    search(.down)
  }

  @IBAction
  private func selectSearchType(_ sender: NSMenuItem)
  {
    guard HistorySearchType.allCases.indices.contains(sender.tag)
    else { return }
    searchType = HistorySearchType.allCases[sender.tag]
  }

  @IBAction
  private func searchPrevious(_ sender: Any?)
  {
    search(.up)
  }

  @IBAction
  private func searchNext(_ sender: Any?)
  {
    search(.down)
  }
}

extension TitleBarController
{
  func updateCustomActionButton(repoPath: String)
  {
    guard let item = customActionToolbarItem
              as? NSMenuToolbarItem
    else { return }

    let actions = CustomActionsStore.actions(for: repoPath)

    if let first = actions.first {
      item.image = NSImage(
          systemSymbolName: first.symbolName,
          accessibilityDescription: first.name)
          ?? NSImage(
              systemSymbolName: "terminal",
              accessibilityDescription: "Actions")
      item.label = first.name
      item.toolTip = first.name
    }
    else {
      item.image = NSImage(
          systemSymbolName: "terminal",
          accessibilityDescription: "Actions")
      item.label = "Actions"
      item.toolTip = "Custom Actions"
    }

    let menu = NSMenu()

    for (index, action) in actions.enumerated() {
      let menuItem = NSMenuItem(
          title: action.name,
          action: #selector(
              HelmWindowController.runCustomAction(_:)),
          keyEquivalent: "")

      menuItem.tag = index
      menuItem.image = NSImage(
          systemSymbolName: action.symbolName,
          accessibilityDescription: action.name)
      menu.addItem(menuItem)
    }

    if !actions.isEmpty {
      menu.addItem(.separator())
    }

    let configItem = NSMenuItem(
        title: actions.isEmpty
            ? "+ Add Action…" : "Edit Actions…",
        action: #selector(
            HelmWindowController.configureActions(_:)),
        keyEquivalent: "")

    menu.addItem(configItem)
    item.menu = menu
  }
}

private struct CodexBarUsageContext: Hashable
{
  let controllerID: ObjectIdentifier
  let agent: CodingAgent

  init(controller: HelmWindowController, agent: CodingAgent)
  {
    controllerID = ObjectIdentifier(controller)
    self.agent = agent
  }
}

extension NSToolbarItem.Identifier
{
  static let navigation: Self = ◊"helm.nav"
  static let spinner: Self = ◊"helm.spinner"
  static let remoteOps: Self = ◊"helm.remote"
  static let stash: Self = ◊"helm.stash"
  static let search: Self = ◊"helm.search"
  static let searchPrevious: Self = ◊"helm.searchPrevious"
  static let searchNext: Self = ◊"helm.searchNext"
  
  static let newBranch: Self = ◊"helm.newBranch"
  static let customAction: Self = ◊"helm.customAction"
  static let codingAgentUsageGroup: Self = ◊"helm.codingAgentUsageGroup"
  static let codingAgent: Self = ◊"helm.codingAgent"
  static let codexBarUsage: Self = ◊"helm.codexBarUsage"
  static let view: Self = ◊"helm.view"
}

extension TitleBarController: NSToolbarDelegate
{
  func toolbar(_ toolbar: NSToolbar,
               itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
  {
    if itemIdentifier == .sidebarTrackingSeparator {
      // Return the saved item to avoid Cocoa throwing exceptions about only
      // one tracking item being allowed.
      return separatorItem
    }
    if itemIdentifier == .newBranch {
      let item = NSToolbarItem(itemIdentifier: .newBranch)

      item.label = "New Branch"
      item.paletteLabel = "New Branch"
      item.toolTip = "New Branch"
      item.image = NSImage(
          systemSymbolName: "arrow.triangle.branch",
          accessibilityDescription: "New Branch")
      item.isBordered = true
      item.target = nil
      item.action = #selector(
          HelmWindowController.newBranch(_:))
      return item
    }
    if itemIdentifier == .customAction {
      let item = NSMenuToolbarItem(
          itemIdentifier: .customAction)

      item.label = "Actions"
      item.paletteLabel = "Actions"
      item.toolTip = "Custom Actions"
      item.image = NSImage(
          systemSymbolName: "terminal",
          accessibilityDescription: "Actions")
      item.isBordered = true
      item.showsIndicator = true
      item.menu = NSMenu()
      item.target = nil
      item.action = #selector(
          HelmWindowController.runDefaultAction(_:))
      return item
    }
    if itemIdentifier == .codingAgent {
      return makeCodingAgentToolbarItem()
    }
    if itemIdentifier == .codingAgentUsageGroup {
      let item = NSToolbarItemGroup(itemIdentifier: .codingAgentUsageGroup)
      let agentItem = makeCodingAgentToolbarItem()

      item.label = "Coding Agent"
      item.paletteLabel = "Coding Agent"
      item.toolTip = "Coding Agent"
      item.subitems = [agentItem]
      codingAgentUsageToolbarGroup = item
      codingAgentToolbarItem = agentItem
      return item
    }
    if itemIdentifier == .codexBarUsage {
      return makeCodexBarUsageToolbarItem()
    }
    return nil
  }
  
  func toolbarWillAddItem(_ notification: Notification)
  {
    guard let item = notification.userInfo?["item"] as? NSToolbarItem
    else { return }

    if fetchMenu == nil {
      makeMenus()
    }
    
    switch item.itemIdentifier {
      case .navigation:
        navButtons = item.view as? NSSegmentedControl
        
      case .spinner:
        spinner = item.view as? NSProgressIndicator
        
      case .remoteOps:
        remoteControls = item.view as? NSSegmentedControl

        let menuItem = NSMenuItem(title: item.label, action: nil,
                                  keyEquivalent: "")

        menuItem.submenu = remoteOpsMenu
        item.menuFormRepresentation = menuItem

        let segmentMenus: [(NSMenu, TitleBarController.RemoteSegment)] = [
              (pullMenu, .pull),
              (pushMenu, .push)]

        for (menu, segment) in segmentMenus {
          remoteControls.setMenu(menu, forSegment: segment.rawValue)
        }

      case .stash:
        stashButton = item.view as? NSSegmentedControl
        stashToolbarItem = item
        stashButton.setMenu(stashMenu, forSegment: 0)

      case .newBranch:
        newBranchToolbarItem = item

      case .customAction:
        customActionToolbarItem = item

      case .codingAgent:
        codingAgentToolbarItem = item as? NSMenuToolbarItem
        startCodexBarUsageUpdates()

      case .codingAgentUsageGroup:
        codingAgentUsageToolbarGroup = item as? NSToolbarItemGroup
        startCodexBarUsageUpdates()

      case .codexBarUsage:
        codexBarUsageToolbarItem = item

      case .sidebarTrackingSeparator:
        separatorItem = item
      
      case .search:
        guard let searchItem = item as? NSSearchToolbarItem
        else { break }
        let field = searchItem.searchField

        searchToolbarItem = searchItem
        searchItem.resignsFirstResponderWithCancel = true
        field.searchMenuTemplate = makeSearchMenu()
        field.setAccessibilityIdentifier(.Search.field)
        updateSearchPlaceholder()

      case .searchPrevious:
        previousSearchItem = item
      
      case .searchNext:
        nextSearchItem = item
        
      default:
        return
    }
  }
}

extension TitleBarController
{
  private var selectedWindowController: HelmWindowController?
  {
    (window?.tabGroup?.selectedWindow?.windowController
     ?? window?.windowController) as? HelmWindowController
  }

  private var codexBarUsageEnabled: Bool
  {
    UserDefaults.helm.codexBarUsageEnabled
  }

  private var currentCodingAgent: CodingAgent
  {
    codingAgent(for: selectedWindowController)
  }

  private func codingAgent(for controller: HelmWindowController?)
    -> CodingAgent
  {
    controller?.terminalPanelController?.terminalController.agent ??
        controller?.repoDocument?.repository?.config.codingAgent ??
        controller?.defaults.codingAgent ??
        UserDefaults.helm.codingAgent
  }

  private var currentCodexBarUsageContext: CodexBarUsageContext?
  {
    guard let controller = selectedWindowController,
          controller.titleBarController === self,
          controller.window?.isMainWindow == true
    else { return nil }

    let agent = codingAgent(for: controller)
    guard agent.codexBarProviderID != nil
    else { return nil }

    return CodexBarUsageContext(controller: controller, agent: agent)
  }

  private func makeCodingAgentToolbarItem() -> NSMenuToolbarItem
  {
    let item = NSMenuToolbarItem(
        itemIdentifier: .codingAgent)

    item.isBordered = true
    item.showsIndicator = true
    item.target = self
    item.action = #selector(showCodingAgentMenu(_:))
    updateCodingAgentItem(item)
    return item
  }

  private func makeCodexBarUsageToolbarItem() -> NSToolbarItem
  {
    let item = NSToolbarItem(itemIdentifier: .codexBarUsage)
    let font = NSFont.monospacedSystemFont(ofSize: 11,
                                           weight: .regular)
    let statusView = TerminalCodexBarStatusView(font: font,
                                                contentSpacing: 8,
                                                verticalInset: 0,
                                                horizontalInset: 8,
                                                meterMinimumWidth: 0)

    item.label = "Usage"
    item.paletteLabel = "Usage"
    item.toolTip = "CodexBar Usage"
    item.view = statusView
    item.minSize = .zero
    item.maxSize = .zero
    codexBarUsageView = statusView
    codexBarUsageToolbarItem = item
    return item
  }

  private func updateCodingAgentItem(_ item: NSMenuToolbarItem)
  {
    let agent = currentCodingAgent
    item.image = agent.image
    item.label = agent.displayName
    item.paletteLabel = "Coding Agent"
    item.toolTip = "Coding Agent: \(agent.displayName)"
    item.menu = makeCodingAgentMenu()
  }

  func refreshCodingAgentItem()
  {
    if let item = codingAgentToolbarItem {
      updateCodingAgentItem(item)
    }
    if codexBarUsageEnabled {
      startCodexBarUsageUpdates()
    }
    else {
      stopCodexBarUsageUpdates()
    }
  }

  func refreshCodexBarUsageAfterRepositoryRefresh(
    for controller: HelmWindowController)
  {
    guard codexBarUsageEnabled
    else {
      stopCodexBarUsageUpdates()
      return
    }

    refreshCodexBarUsageItem(for: controller)
  }

  func refreshCodexBarUsageFromToolbar(for controller: HelmWindowController)
  {
    guard codexBarUsageEnabled
    else {
      stopCodexBarUsageUpdates()
      return
    }

    refreshCodexBarUsageItem(for: controller, force: true)
  }

  private func startCodexBarUsageUpdates()
  {
    guard codexBarUsageEnabled
    else {
      stopCodexBarUsageUpdates()
      return
    }

    refreshCodexBarUsageItem()
    codexBarUsageRefreshTimer?.invalidate()
    codexBarUsageRefreshTimer = Timer.scheduledTimer(
        withTimeInterval: Self.codexBarUsageRefreshInterval,
        repeats: true) {
      [weak self] _ in
      self?.refreshCodexBarUsageItem()
    }
  }

  private func stopCodexBarUsageUpdates()
  {
    codexBarUsageRefreshTimer?.invalidate()
    codexBarUsageRefreshTimer = nil
    clearCodexBarUsageState()
    hideCodexBarUsageItem()
  }

  private func refreshCodexBarUsageItem(force: Bool = false)
  {
    guard codexBarUsageEnabled
    else {
      stopCodexBarUsageUpdates()
      return
    }

    guard let context = currentCodexBarUsageContext
    else {
      clearCodexBarUsageState()
      hideCodexBarUsageItem()
      return
    }

    refreshCodexBarUsageItem(for: context, force: force)
  }

  private func refreshCodexBarUsageItem(for controller: HelmWindowController,
                                        force: Bool = false)
  {
    guard codexBarUsageEnabled
    else {
      stopCodexBarUsageUpdates()
      return
    }

    guard controller.titleBarController === self,
          controller.window?.isMainWindow == true,
          selectedWindowController === controller
    else { return }

    let agent = codingAgent(for: controller)
    guard agent.codexBarProviderID != nil
    else {
      clearCodexBarUsageState()
      hideCodexBarUsageItem()
      return
    }

    refreshCodexBarUsageItem(
      for: CodexBarUsageContext(controller: controller, agent: agent),
      force: force
    )
  }

  private func refreshCodexBarUsageItem(for context: CodexBarUsageContext,
                                        force: Bool = false)
  {
    guard !codexBarUsageFetchInProgress
    else { return }

    if codexBarUsageContext != nil,
       codexBarUsageContext != context {
      clearCodexBarUsageState()
      hideCodexBarUsageItem()
    }

    // A user-driven agent switch must fetch right away. Failed fetches still
    // update the attempted context so repository refreshes do not bypass the
    // throttle and repeatedly trigger provider credential prompts.
    let contextChanged = context != codexBarUsageFetchContext
    let now = Date()
    let lastRefresh = lastCodexBarUsageRefreshByContext[context] ??
        .distantPast
    let lastFailure = lastCodexBarUsageFailureByContext[context] ??
        .distantPast

    guard force ||
          contextChanged ||
          (now.timeIntervalSince(lastRefresh) >=
             Self.codexBarUsageRefreshInterval &&
           now.timeIntervalSince(lastFailure) >=
             Self.codexBarUsageFailureRetryInterval)
    else { return }

    codexBarUsageFetchContext = context
    lastCodexBarUsageRefreshByContext[context] = now
    codexBarUsageFetchInProgress = true
    CodexBarUsageFetcher.shared.fetch(for: context.agent) {
      [weak self] status in
      guard let self
      else { return }

      self.codexBarUsageFetchInProgress = false
      guard self.codexBarUsageEnabled,
            context == self.currentCodexBarUsageContext
      else { return }

      if let status {
        self.lastCodexBarUsageFailureByContext[context] = nil
        self.codexBarUsageContext = context
        self.ensureCodexBarUsageItem()
        self.codexBarUsageView?.update(with: status)
        self.showCodexBarUsageItem()
      }
      else {
        self.lastCodexBarUsageFailureByContext[context] = Date()
        self.clearCodexBarUsageState()
        self.hideCodexBarUsageItem()
      }
    }
  }

  private func clearCodexBarUsageState()
  {
    codexBarUsageContext = nil
    codexBarUsageFetchContext = nil
  }

  private func showCodexBarUsageItem()
  {
    ensureCodexBarUsageItem()

    guard let item = codexBarUsageToolbarItem,
          let view = codexBarUsageView
    else { return }

    view.isHidden = false
    let size = view.intrinsicContentSize

    item.minSize = size
    item.maxSize = size
  }

  private func hideCodexBarUsageItem()
  {
    if let group = codingAgentUsageToolbarGroup,
       let agentItem = codingAgentToolbarItem {
      group.subitems = [agentItem]
    }

    guard let toolbar = window?.toolbar
    else {
      codexBarUsageView?.isHidden = true
      codexBarUsageToolbarItem?.minSize = .zero
      codexBarUsageToolbarItem?.maxSize = .zero
      return
    }

    if let usageIndex = toolbar.items.firstIndex(where: {
      $0.itemIdentifier == .codexBarUsage
    }) {
      let nextIndex = usageIndex + 1

      if nextIndex < toolbar.items.count,
         toolbar.items[nextIndex].itemIdentifier == .space {
        toolbar.removeItem(at: nextIndex)
      }
      toolbar.removeItem(at: usageIndex)
    }

    codexBarUsageView = nil
    codexBarUsageToolbarItem = nil
  }

  private func ensureCodexBarUsageItem()
  {
    if let group = codingAgentUsageToolbarGroup {
      let agentItem = codingAgentToolbarItem ?? makeCodingAgentToolbarItem()
      let usageItem = codexBarUsageToolbarItem ??
          makeCodexBarUsageToolbarItem()

      codingAgentToolbarItem = agentItem
      if !group.subitems.contains(where: {
        $0.itemIdentifier == .codexBarUsage
      }) {
        group.subitems = [agentItem, usageItem]
      }
      ensureSpaceAfterCodingAgentGroup()
      return
    }

    guard let toolbar = window?.toolbar
    else { return }

    if !toolbar.items.contains(where: {
      $0.itemIdentifier == .codexBarUsage
    }) {
      let agentIndex = toolbar.items.firstIndex {
        $0.itemIdentifier == .codingAgent
      } ?? 2
      toolbar.insertItem(withItemIdentifier: .codexBarUsage,
                         at: min(agentIndex + 1, toolbar.items.count))
    }

    guard let usageIndex = toolbar.items.firstIndex(where: {
      $0.itemIdentifier == .codexBarUsage
    })
    else { return }

    let nextIndex = usageIndex + 1
    if nextIndex >= toolbar.items.count ||
       toolbar.items[nextIndex].itemIdentifier != .space {
      toolbar.insertItem(withItemIdentifier: .space,
                         at: min(nextIndex, toolbar.items.count))
    }
  }

  private func ensureSpaceAfterCodingAgentGroup()
  {
    guard let toolbar = window?.toolbar,
          let groupIndex = toolbar.items.firstIndex(where: {
            $0.itemIdentifier == .codingAgentUsageGroup
          })
    else { return }

    let nextIndex = groupIndex + 1

    if nextIndex >= toolbar.items.count ||
       toolbar.items[nextIndex].itemIdentifier != .space {
      toolbar.insertItem(withItemIdentifier: .space,
                         at: min(nextIndex, toolbar.items.count))
    }
  }

  private func makeCodingAgentMenu() -> NSMenu
  {
    let menu = NSMenu()

    for (index, agent) in CodingAgent.allCases.enumerated() {
      let item = NSMenuItem(
          title: agent.displayName,
          action: #selector(selectCodingAgent(_:)),
          keyEquivalent: "")

      item.target = self
      item.tag = index
      item.image = agent.image
      item.state = agent == currentCodingAgent ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  @objc
  private func showCodingAgentMenu(_ sender: Any?)
  {
    // NSMenuToolbarItem displays the menu automatically; this action
    // is a fallback for accessibility or keyboard invocation.
  }

  @objc
  private func selectCodingAgent(_ sender: NSMenuItem)
  {
    guard CodingAgent.allCases.indices.contains(sender.tag)
    else { return }
    let agent = CodingAgent.allCases[sender.tag]
    guard agent != currentCodingAgent
    else { return }

    guard let window = window
    else { return }

    NSAlert.confirm(
        message: ›"Switch to \(agent.displayName)?",
        infoString: ›"The current terminal session will be terminated and restarted with \(agent.displayName).",
        actionName: ›"Switch",
        parentWindow: window) { [weak self] in
      let targetController = self?.selectedWindowController

      if let config = targetController?.repoDocument?.repository?.config {
        config.codingAgent = agent
      }
      else {
        UserDefaults.helm.codingAgent = agent
      }
      if let item = self?.codingAgentToolbarItem {
        self?.updateCodingAgentItem(item)
      }
      targetController?.restartTerminal(with: agent)
      if let targetController {
        self?.refreshCodexBarUsageItem(for: targetController, force: true)
      }
      else if agent.codexBarProviderID == nil {
        self?.clearCodexBarUsageState()
        self?.hideCodexBarUsageItem()
      }
    }
  }

  private static let codexBarUsageRefreshInterval: TimeInterval = 5 * 60
  private static let codexBarUsageFailureRetryInterval: TimeInterval = 30 * 60
}

extension TitleBarController: NSMenuItemValidation
{
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool
  {
    switch menuItem.action {
      case #selector(selectSearchType(_:)),
           #selector(selectCodingAgent(_:)):
        return true
      default:
        return false
    }
  }
}

extension TitleBarController: NSToolbarItemValidation
{
  func validateToolbarItem(_ item: NSToolbarItem) -> Bool
  {
    switch item.itemIdentifier {
      case .stash:
        return reviewActive
      case .search:
        return searchEnabled && !reviewActive
      case .searchPrevious, .searchNext:
        return searchEnabled && !reviewActive
            && !searchText.isEmpty
      default:
        return true
    }
  }
}

extension TitleBarController: NSSearchFieldDelegate
{
  func controlTextDidChange(_ obj: Notification)
  {
    if let field = obj.object as? NSSearchField {
      searchText = field.stringValue
    }
    updateSearchControls()
  }

  func controlTextDidBeginEditing(_ obj: Notification)
  {
    updateSearchControls()
  }

  func controlTextDidEndEditing(_ obj: Notification)
  {
    guard let field = obj.object as? NSSearchField
    else { return }
    if field.stringValue.isEmpty {
      searchText = ""
      hideSearch()
    }
    else {
      searchText = field.stringValue
    }
    updateSearchControls()
  }

  func searchFieldDidStartSearching(_ sender: NSSearchField)
  {
    searchText = sender.stringValue
    updateSearchControls()
  }

  func searchFieldDidEndSearching(_ sender: NSSearchField)
  {
    searchText = ""
    sender.stringValue = ""
    updateSearchControls()
  }
}
