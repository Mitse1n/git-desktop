import AppKit
import GitDeskCore

final class LogSubjectCell: NSView, LogExpandableCell {
  var compactReferences = true
  var showTagNames = false
  var referencesOnLeft = false
  var dimMerge = true
  var graph: GraphRow?
  var graphColumnWidth: CGFloat = 0
  var isHead = false
  var commit: Commit? {
    didSet {
      needsDisplay = true
      setAccessibilityLabel(commit?.subject)
      toolTip = commit?.decorations.joined(separator: "\n")
    }
  }
  private struct ReferenceBadge {
    let name: String
    let title: String
    let rect: NSRect
    let iconWidth: CGFloat
    let stacked: Bool
  }
  private func textLayout(for commit: Commit) -> (badges: [ReferenceBadge], message: NSRect) {
    let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.text]
    var right = bounds.width - 8
    var badges: [ReferenceBadge] = []
    let refs = commit.decorations.filter { $0 != "HEAD" }
    let primary = refs.first { $0.hasPrefix("HEAD -> ") }
      ?? refs.first { !$0.hasPrefix("tag: ") } ?? refs.first
    var visible = compactReferences ? primary.map { [$0] } ?? [] : refs
    if showTagNames { visible += refs.filter { $0.hasPrefix("tag: ") && !visible.contains($0) } }
    let messageStart = 5 + max(0, (graph.map { GraphCell.requiredWidth(lanes: $0.laneCount) } ?? 0) - graphColumnWidth)
    var left = messageStart
    for name in visible.reversed() {
      let fullName = name.replacingOccurrences(of: "HEAD -> ", with: "").replacingOccurrences(
        of: "tag: ", with: "")
      let clean = name.hasPrefix("tag: ") && !showTagNames ? "" : fullName
      if clean == "HEAD" { continue }
      let stacked = compactReferences && (refs.count > 1 || name.hasPrefix("HEAD -> "))
      let iconWidth: CGFloat = stacked ? 22 : 17
      let width = min(210, (clean as NSString).size(withAttributes: attrs).width + iconWidth)
      if right - width - left < 70 { break }
      let rect = NSRect(x: referencesOnLeft ? left : right - width, y: 5, width: width, height: 18)
      badges.append(ReferenceBadge(name: name, title: clean, rect: rect,
        iconWidth: iconWidth, stacked: stacked))
      if referencesOnLeft { left += width + 5 } else { right -= width + 5 }
    }
    let messageX = referencesOnLeft ? left : messageStart
    return (badges, NSRect(x: messageX, y: 6, width: max(0, right - messageX - 5), height: 18))
  }
  var hoverText: LogHoverText? {
    guard let commit else { return nil }
    return LogHoverText(text: commit.subject, font: Theme.font,
      color: dimMerge && commit.parents.count > 1 ? Theme.muted : Theme.text,
      rect: textLayout(for: commit).message)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let commit else { return }
    // The graph has a small shared base column; wider rows continue into
    // the subject cell. Only this row's text moves, like IDEA's log renderer.
    if let graph {
      NSGraphicsContext.saveGraphicsState()
      bounds.clip()
      GraphCell.draw(graph, isHead: isHead, height: bounds.height, offsetX: -graphColumnWidth)
      NSGraphicsContext.restoreGraphicsState()
    }
    let layout = textLayout(for: commit)
    for badge in layout.badges {
      let rect = badge.rect
      if badge.stacked {
        Theme.green.setStroke()
        let back = NSBezierPath()
        back.lineWidth = 1
        back.move(to: NSPoint(x: rect.minX + 7, y: 19))
        back.line(to: NSPoint(x: rect.minX, y: 12))
        back.line(to: NSPoint(x: rect.minX + 5, y: 7))
        back.stroke()
      }
      let color = badge.name.hasPrefix("tag: ") || badge.name.hasPrefix("HEAD -> ") ? Theme.yellow : Theme.green
      color.setStroke()
      let offset: CGFloat = badge.stacked ? 5 : 0
      let tag = NSBezierPath()
      tag.lineWidth = 1
      tag.move(to: NSPoint(x: rect.minX + offset + 1, y: 12))
      tag.line(to: NSPoint(x: rect.minX + offset + 8, y: 19))
      tag.line(to: NSPoint(x: rect.minX + offset + 13, y: 19))
      tag.line(to: NSPoint(x: rect.minX + offset + 13, y: 14))
      tag.line(to: NSPoint(x: rect.minX + offset + 6, y: 7))
      tag.close()
      tag.stroke()
      NSBezierPath(ovalIn: NSRect(x: rect.minX + offset + 9, y: 15.5, width: 1.5, height: 1.5)).stroke()
      (badge.title as NSString).draw(
        in: NSRect(x: rect.minX + badge.iconWidth, y: 6, width: rect.width - badge.iconWidth, height: 16),
        withAttributes: [.font: Theme.font, .foregroundColor: Theme.muted])
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    (commit.subject as NSString).draw(
      in: layout.message,
      withAttributes: [.font: Theme.font, .foregroundColor: dimMerge && commit.parents.count > 1 ? Theme.muted : Theme.text, .paragraphStyle: paragraph])
  }
}

final class RepositoryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSSplitViewDelegate
{
  var repository: GitRepository?
  var snapshot: RepositorySnapshot?
  var filter = LogFilter()
  var allAuthors = Set<String>()
  var graphs: [GraphRow] = []
  var currentBranchHistory = Set<String>()
  var displayedCurrentBranchHighlight = false
  var highlightCurrentBranch = UserDefaults.standard.object(forKey: "logHighlightCurrentBranch") as? Bool ?? true {
    didSet { UserDefaults.standard.set(highlightCurrentBranch, forKey: "logHighlightCurrentBranch") }
  }
  var currentUserEmail = ""
  var branchesLoaded = false
  var branchExpansionState: [String: Bool] = [:]
  var branchNodes: [BranchNode] = []
  var loadedDetailHash: String?
  var pendingDiffHash: String?
  var selectedCommit: Commit?
  var displayedLogCommits: [Commit] = []
  private(set) var historyPresentation: RepositoryHistoryPresentation?
  var rebuildingLog = false
  var detailFiles: [FileChange] = []
  var detailNodes: [FileNode] = []
  var workingRows: [WorkingRow] = []
  var ignoredPaths: [String] = []
  var commitModules: [CommitModule] = []
  var collapsedChanges = Set<String>()
  var comparison: (String, String)?
  var mode = "Log"
  var selectedPaths = Set<String>()
  var amendDraft: String?
  var amendLoadToken = 0
  let queue = DispatchQueue(label: "gitdesk.git", qos: .userInitiated, autoreleaseFrequency: .workItem)
  var epoch = 0, loadToken = 0, detailToken = 0
  var isBusy = false
  var isRefreshing = false
  var pendingRefresh = false
  var pendingRefreshLogOnly = true
  var debounce: DispatchWorkItem?
  var watcher: Timer?
  private var dateRefreshTimer: Timer?
  private let logDateFormatter = LogDateFormatter()
  var conflictWindows: [ConflictWindowController] = []
  var diffWindows: [DiffWindowController] = []
  var revisionWindows: [RevisionBrowserWindowController] = []
  var operationControls: NSStackView!
  let operationLabel = label("Rebase paused", color: Theme.yellow, size: 12)
  let split = GitSplitView()
  let branchOutline = BranchOutline()
  var branchDeleteButton: ActionButton?
  var branchCompareButton: ActionButton?
  var branchHeadButton: ActionButton?
  var branchFavoriteButton: ActionButton?
  let logTable = LogTable()
  let filesTable = MenuOutline()
  let changesTable = CommitChangesTable()
  let branchSearch = FlatSearchField(frame: .zero)
  let logSearch = FlatSearchField(frame: .zero)
  let statusLabel = label("Open a Git repository to begin", color: Theme.muted, size: 11)
  let repoLabel = HeaderMenuButton("GitDesk", kind: .repository)
  var headerBranchPicker: BranchPicker?
  let branchLabel = HeaderMenuButton("No branch", kind: .branch)
  let repositoryHeader = RepositoryHeader()
  var headerControls: NSStackView!
  let fileEmptyLabel = label("Select commit to view changes", color: Theme.muted)
  let detailEmptyLabel = label("Commit details", color: Theme.muted)
  let detailsText = NSTextView()
  let consoleText = ConsoleTextView()
  let commitMessage = PlaceholderTextView()
  let amend = CommitCheckbox(target: nil, action: nil)
  var commitAuthor = ""
  var commitSignOff = false
  let emptyLabel = label("No repository selected.", color: Theme.muted)
  let emptyAction = ActionButton("Open repository…") {}
  let branchPopup = FilterPopup(frame: .zero, pullsDown: false)
  let userPopup = FilterPopup(frame: .zero, pullsDown: false)
  let datePopup = FilterPopup(frame: .zero, pullsDown: false)
  let regexButton = ActionButton(".*", tooltip: "Regex") {}
  let caseButton = ActionButton("Cc", tooltip: "Match Case") {}
  let progress = NSProgressIndicator()
  private var themeObserver: NSObjectProtocol?
  private var bodyEdgeConstraints: [NSLayoutConstraint] = []
  var mainBody = Surface()
  var logBody = Surface()
  var commitBody = Surface()
  var consoleBody = Surface()
  var terminalBody = Surface()
  var hostingBody = Surface()
  let terminalWorkspace = TerminalWorkspace()
  let hostingWorkspace = HostingWorkspace()
  var branchPanel: NSView!
  var logTab: ActionButton!
  var consoleTab: ActionButton!
  var terminalTab: ActionButton!
  var hostingTab: ActionButton!
  var commitTab: ActionButton!
  var commitButton: ActionButton!
  var commitSections: GitSplitView!
  var commitCompositionInitialized = false
  var groupCommitDirectories = UserDefaults.standard.object(forKey: "commitGroupByDirectory") as? Bool ?? true {
    didSet { UserDefaults.standard.set(groupCommitDirectories, forKey: "commitGroupByDirectory") }
  }
  var groupCommitModules = UserDefaults.standard.bool(forKey: "commitGroupByModule") {
    didSet { UserDefaults.standard.set(groupCommitModules, forKey: "commitGroupByModule") }
  }
  var showIgnoredFiles = UserDefaults.standard.bool(forKey: "commitShowIgnoredFiles") {
    didSet { UserDefaults.standard.set(showIgnoredFiles, forKey: "commitShowIgnoredFiles") }
  }
  var commitRollbackButton: ActionButton!
  var commitDiffButton: ActionButton!
  let sectionTitle = label("Git", bold: true)
  var lastConsole = ""
  var favoriteOnly = false
  var groupBranches = UserDefaults.standard.object(forKey: "branchGroupDirectories") as? Bool ?? true {
    didSet { UserDefaults.standard.set(groupBranches, forKey: "branchGroupDirectories") }
  }
  var compactReferences = UserDefaults.standard.object(forKey: "logCompactReferences") as? Bool ?? true {
    didSet { UserDefaults.standard.set(compactReferences, forKey: "logCompactReferences") }
  }
  var showLongGraphEdges = UserDefaults.standard.bool(forKey: "logShowLongEdges") {
    didSet { UserDefaults.standard.set(showLongGraphEdges, forKey: "logShowLongEdges") }
  }
  var showLogTagNames = UserDefaults.standard.bool(forKey: "logShowTagNames") {
    didSet { UserDefaults.standard.set(showLogTagNames, forKey: "logShowTagNames") }
  }
  var referencesOnLeft = UserDefaults.standard.bool(forKey: "logReferencesOnLeft") {
    didSet { UserDefaults.standard.set(referencesOnLeft, forKey: "logReferencesOnLeft") }
  }
  var highlightMyCommits = UserDefaults.standard.object(forKey: "logHighlightMyCommits") as? Bool ?? true {
    didSet { UserDefaults.standard.set(highlightMyCommits, forKey: "logHighlightMyCommits") }
  }
  var highlightMergeCommits = UserDefaults.standard.object(forKey: "logHighlightMergeCommits") as? Bool ?? true {
    didSet { UserDefaults.standard.set(highlightMergeCommits, forKey: "logHighlightMergeCommits") }
  }
  var branchClickUpdatesFilter = UserDefaults.standard.bool(forKey: "branchClickUpdatesFilter") {
    didSet { UserDefaults.standard.set(branchClickUpdatesFilter, forKey: "branchClickUpdatesFilter") }
  }
  var branchClickNavigates = UserDefaults.standard.bool(forKey: "branchClickNavigates") {
    didSet { UserDefaults.standard.set(branchClickNavigates, forKey: "branchClickNavigates") }
  }
  var branchHidden = false
  var showTags = UserDefaults.standard.object(forKey: "branchShowTags") as? Bool ?? true {
    didSet { UserDefaults.standard.set(showTags, forKey: "branchShowTags") }
  }
  var groupDetailDirectories = UserDefaults.standard.object(forKey: "detailGroupDirectories") as? Bool ?? true {
    didSet { UserDefaults.standard.set(groupDetailDirectories, forKey: "detailGroupDirectories") }
  }
  var groupDetailModules = UserDefaults.standard.object(forKey: "detailGroupModules") as? Bool ?? true {
    didSet { UserDefaults.standard.set(groupDetailModules, forKey: "detailGroupModules") }
  }
  var showDetails = UserDefaults.standard.object(forKey: "detailShowDetails") as? Bool ?? true {
    didSet { UserDefaults.standard.set(showDetails, forKey: "detailShowDetails") }
  }
  var detailTextArea: NSView?
  var historyPageSize = 2000
  var loadedLogFilter: LogFilter?
  var isLoadingMoreHistory = false
  var historyPageToken = 0
  var detailsSplit: NSSplitView?
  var initializedLayout = false
  var favoriteRefs: Set<String> {
    get { BranchTree.favorites() }
    set { UserDefaults.standard.set(Array(newValue), forKey: "favoriteRefs") }
  }
  override func loadView() {
    view = Surface(Theme.chrome)
    buildUI()
    themeObserver = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) {
      [weak self] _ in self?.updateThemeLayout()
    }
    dateRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      guard let self, self.view.window?.isVisible == true, !self.logTable.isHiddenOrHasHiddenAncestor else { return }
      self.refreshLogDates()
    }
    dateRefreshTimer?.tolerance = 5
    watcher = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      guard let self, self.repository != nil, !self.isBusy, !self.isRefreshing, !self.isLoadingMoreHistory, self.debounce == nil,
        self.view.window?.attachedSheet == nil, NSApp.modalWindow == nil
      else { return }
      self.refresh(silent: true)
    }
  }
  deinit {
    terminalWorkspace.shutdown()
    watcher?.invalidate()
    dateRefreshTimer?.invalidate()
    if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
  }
  private func updateThemeLayout() {
    bodyEdgeConstraints[0].constant = Theme.current.isIsland ? 10 : 0
    bodyEdgeConstraints[1].constant = Theme.current.isIsland ? -10 : 0
    logTable.dismissTextExpansion()
    branchOutline.dismissTextExpansion()
    Theme.refresh(view)
  }
  func buildUI() {
    repoLabel.handler = { [weak self] in self?.showRecent() }
    repoLabel.toolTip = "Open or switch repository (⌘O)"
    branchLabel.handler = { [weak self] in self?.showBranchMenu() }
    branchLabel.toolTip = "Branches"
    let header = repositoryHeader
    header.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header)
    let menuGap = NSView()
    menuGap.widthAnchor.constraint(equalToConstant: 16).isActive = true
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let top = row(
      [
        repoLabel, menuGap, branchLabel, spacer,
        ActionButton("Fetch", symbol: "arrow.down.to.line") { [weak self] in
          self?.remoteAction("fetch")
        }, ActionButton("Pull", symbol: "arrow.down") { [weak self] in self?.remoteAction("pull") },
        ActionButton("Push", symbol: "arrow.up") { [weak self] in self?.push() },
        ActionButton(symbol: "ellipsis", tooltip: "Repository Actions") { [weak self] in
          self?.showRepositoryMenu()
        },
      ], spacing: 8)
    top.translatesAutoresizingMaskIntoConstraints = false
    headerControls = top
    mainBody = Surface()
    mainBody.wantsLayer = true
    mainBody.islandPanel = true
    mainBody.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainBody)
    logTab = ActionButton("Log") { [weak self] in self?.setMode("Log") }
    terminalTab = ActionButton("Terminal") { [weak self] in self?.setMode("Terminal") }
    hostingTab = ActionButton("Reviews") { [weak self] in self?.setMode("Reviews") }
    consoleTab = ActionButton("Console") { [weak self] in self?.setMode("Console") }
    commitTab = ActionButton("Commit") { [weak self] in self?.setMode("Commit") }
    for tab in [logTab, consoleTab, commitTab, terminalTab, hostingTab] { tab?.isTab = true }
    let tabSpacer = NSView()
    operationControls = row([
      operationLabel,
      ActionButton("Resolve Conflicts") { [weak self] in self?.setMode("Commit") },
      ActionButton("Continue") { [weak self] in
        if let operation = self?.snapshot?.operation { self?.continueOperation(operation) }
      },
      ActionButton("Skip…") { [weak self] in self?.skipRebaseCommit() },
      ActionButton("Abort…") { [weak self] in
        if let operation = self?.snapshot?.operation { self?.abortHistoryOperation(operation) }
      },
    ], spacing: 6)
    operationControls.isHidden = true
    let tabs = row(
      [
        sectionTitle, logTab, consoleTab, commitTab, terminalTab, hostingTab, tabSpacer, operationControls,
        ActionButton(symbol: "arrow.clockwise", tooltip: "Refresh (⌘R)") { [weak self] in
          self?.refresh()
        },
      ], spacing: 16)
    tabs.translatesAutoresizingMaskIntoConstraints = false
    mainBody.addSubview(tabs)
    buildLog()
    buildCommit()
    buildConsole()
    buildHosting()
    for body in [logBody, commitBody, consoleBody, terminalBody, hostingBody] {
      body.translatesAutoresizingMaskIntoConstraints = false
      mainBody.addSubview(body)
      NSLayoutConstraint.activate([
        body.leadingAnchor.constraint(equalTo: mainBody.leadingAnchor),
        body.trailingAnchor.constraint(equalTo: mainBody.trailingAnchor),
        body.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 1),
        body.bottomAnchor.constraint(equalTo: mainBody.bottomAnchor),
      ])
    }
    let status = row([statusLabel, NSView(), progress], spacing: 8)
    progress.style = .spinning
    progress.controlSize = .small
    progress.isDisplayedWhenStopped = false
    status.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(status)
    bodyEdgeConstraints = [
      mainBody.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.current.isIsland ? 10 : 0),
      mainBody.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: Theme.current.isIsland ? -10 : 0),
    ]
    NSLayoutConstraint.activate(bodyEdgeConstraints)
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      header.topAnchor.constraint(equalTo: view.topAnchor),
      header.heightAnchor.constraint(equalToConstant: 42),
      mainBody.topAnchor.constraint(equalTo: header.bottomAnchor),
      mainBody.bottomAnchor.constraint(equalTo: status.topAnchor),
      status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      status.heightAnchor.constraint(equalToConstant: 26),
      tabs.leadingAnchor.constraint(equalTo: mainBody.leadingAnchor, constant: 14),
      tabs.trailingAnchor.constraint(equalTo: mainBody.trailingAnchor, constant: -10),
      tabs.topAnchor.constraint(equalTo: mainBody.topAnchor),
      tabs.heightAnchor.constraint(equalToConstant: 40),
    ])
    setMode("Log")
  }
  func buildLog() {
    split.isVertical = true
    split.dividerStyle = .thin
    split.delegate = self
    split.autosaveName = "GitLogSplit"
    branchSearch.placeholderString = "Branch or tag"
    branchSearch.delegate = self
    branchSearch.sendsSearchStringImmediately = true
    branchSearch.focusRingType = .none
    let branchColumn = NSTableColumn(identifier: .init("branch"))
    branchColumn.resizingMask = []
    branchColumn.maxWidth = .greatestFiniteMagnitude
    branchColumn.minWidth = 0
    branchOutline.addTableColumn(branchColumn)
    branchOutline.outlineTableColumn = branchColumn
    configureTable(branchOutline)
    branchOutline.allowsMultipleSelection = true
    branchOutline.columnAutoresizingStyle = .noColumnAutoresizing
    branchOutline.autoresizesOutlineColumn = false
    branchOutline.contentWidthForItem = { [weak self] item in
      guard let self, let node = item as? BranchNode else { return 0 }
      let font = node.branch?.current == true ? NSFont.systemFont(ofSize: 13, weight: .semibold) : Theme.font
      let iconWidth: CGFloat = node.branch != nil || !self.branchNodes.contains(node) ? 20 : 0
      return ceil((node.title as NSString).size(withAttributes: [.font: font]).width) + iconWidth + 12
    }
    branchOutline.rowHeight = 25
    branchOutline.indentationPerLevel = 18
    branchOutline.dataSource = self
    branchOutline.delegate = self
    branchOutline.target = self
    branchOutline.doubleAction = #selector(branchDoubleClick)
    branchOutline.action = #selector(branchSingleClick)
    branchOutline.setAccessibilityLabel("Git branches")
    branchOutline.menuProvider = { [weak self] in self?.branchContextMenu() ?? NSMenu() }
    let toolbarRail = NSStackView()
    toolbarRail.orientation = .vertical
    toolbarRail.spacing = 0
    let actions: [(String, String, () -> Void)] = [
      ("plus", "New Branch", { [weak self] in self?.newBranch() }),
      ("trash", "Delete Branch", { [weak self] in self?.deleteBranch() }),
      ("arrow.left.arrow.right", "Compare with Current", { [weak self] in self?.compareBranch() }),
      ("magnifyingglass", "Search Branches", { [weak self] in
        self?.view.window?.makeFirstResponder(self?.branchSearch)
      }),
      ("arrow.down.left.and.arrow.up.right", "Group Branches by Prefix", { [weak self] in
        self?.groupBranches.toggle()
        self?.rebuildBranches()
      }),
      (
        "star", "Mark/Unmark As Favorite", { [weak self] in
          self?.toggleSelectedBranchFavorites()
        }
      ), ("scope", "Navigate Log to Selected Branch Head", { [weak self] in
        self?.navigateSelectedBranchHead()
      }),
      ("gearshape", "Branches Pane Settings", { [weak self] in self?.branchViewOptions() }),
      (
        "chevron.down", "Expand All",
        { [weak self] in self?.branchOutline.expandItem(nil, expandChildren: true) }
      ),
      (
        "chevron.up", "Collapse All",
        { [weak self] in self?.branchOutline.collapseItem(nil, collapseChildren: true) }
      ),
    ]
    for (icon, title, action) in actions {
      let button = ActionButton(symbol: icon, tooltip: title, size: 26, action: action)
      if icon == "gearshape" {
        button.handler = { [weak self, weak button] in self?.branchViewOptions(anchor: button) }
      }
      if icon == "trash" {
        branchDeleteButton = button
        button.isEnabled = false
      }
      if icon == "arrow.left.arrow.right" {
        branchCompareButton = button
        button.isEnabled = false
      }
      if icon == "scope" {
        branchHeadButton = button
        button.isEnabled = false
      }
      if icon == "star" {
        branchFavoriteButton = button
        button.isEnabled = false
      }
      toolbarRail.addArrangedSubview(button)
    }
    let branchSearchBar = row([branchSearch])
    branchSearch.widthAnchor.constraint(equalTo: branchSearchBar.widthAnchor).isActive = true
    let branchScroll = scrollView(branchOutline)
    branchScroll.hasHorizontalScroller = true
    let branchArea = Surface()
    branchScroll.translatesAutoresizingMaskIntoConstraints = false
    branchArea.addSubview(branchScroll)
    NSLayoutConstraint.activate([
      branchScroll.leadingAnchor.constraint(equalTo: branchArea.leadingAnchor, constant: 18),
      branchScroll.trailingAnchor.constraint(equalTo: branchArea.trailingAnchor),
      branchScroll.topAnchor.constraint(equalTo: branchArea.topAnchor),
      branchScroll.bottomAnchor.constraint(equalTo: branchArea.bottomAnchor),
    ])
    let branchTree = makePanel(branchSearchBar, body: branchArea, height: 34)
    let branchContent = Surface()
    toolbarRail.translatesAutoresizingMaskIntoConstraints = false
    branchTree.translatesAutoresizingMaskIntoConstraints = false
    branchContent.addSubview(toolbarRail)
    branchContent.addSubview(branchTree)
    NSLayoutConstraint.activate([
      toolbarRail.leadingAnchor.constraint(equalTo: branchContent.leadingAnchor, constant: 2),
      toolbarRail.topAnchor.constraint(equalTo: branchContent.topAnchor, constant: 29),
      toolbarRail.widthAnchor.constraint(equalToConstant: 30),
      branchTree.leadingAnchor.constraint(equalTo: toolbarRail.trailingAnchor, constant: 1),
      branchTree.trailingAnchor.constraint(equalTo: branchContent.trailingAnchor),
      branchTree.topAnchor.constraint(equalTo: branchContent.topAnchor),
      branchTree.bottomAnchor.constraint(equalTo: branchContent.bottomAnchor),
    ])
    branchPanel = branchContent
    split.addArrangedSubview(branchContent)
    logSearch.placeholderString = "Text or hash"
    logSearch.delegate = self
    logSearch.sendsSearchStringImmediately = true
    logSearch.focusRingType = .none
    logSearch.translatesAutoresizingMaskIntoConstraints = false
    logSearch.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    logSearch.showsOutline = false
    regexButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
    caseButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
    let searchBox = Surface()
    searchBox.layer?.borderWidth = 1
    searchBox.borderColor = Theme.border
    searchBox.layer?.cornerRadius = 3
    pin(row([logSearch, regexButton, caseButton], spacing: 1), to: searchBox)
    searchBox.heightAnchor.constraint(equalToConstant: 30).isActive = true
    searchBox.widthAnchor.constraint(equalToConstant: 170).isActive = true
    regexButton.handler = { [weak self] in
      guard let self else { return }
      self.filter.regex.toggle()
      self.regexButton.contentTintColor = self.filter.regex ? Theme.blue : Theme.text
      self.refresh(logOnly: true)
    }
    caseButton.handler = { [weak self] in
      guard let self else { return }
      self.filter.matchCase.toggle()
      self.caseButton.contentTintColor = self.filter.matchCase ? Theme.blue : Theme.text
      self.refresh(logOnly: true)
    }
    for popup in [branchPopup, userPopup, datePopup] {
      popup.isBordered = false
      popup.font = Theme.font
      popup.contentTintColor = Theme.muted
      popup.setContentHuggingPriority(.required, for: .horizontal)
    }
    branchPopup.addItem(withTitle: "Branch")
    userPopup.addItem(withTitle: "User")
    datePopup.addItems(withTitles: [
      "Date", "Last 24 hours", "Last 7 days", "Last 30 days", "Custom…",
    ])
    branchPopup.target = self
    branchPopup.action = #selector(branchFilterChanged)
    userPopup.target = self
    userPopup.action = #selector(userFilterChanged)
    datePopup.target = self
    datePopup.action = #selector(dateFilterChanged)
    let logOptions = ActionButton(symbol: "eye", tooltip: "Log View Options", size: 26) {}
    logOptions.handler = { [weak self, weak logOptions] in self?.logViewOptions(anchor: logOptions) }
    let moreFilters = ActionButton(symbol: "chevron.right", tooltip: "More Filters and View Options", size: 26) {}
    moreFilters.handler = { [weak self, weak moreFilters] in self?.filterMenu(anchor: moreFilters) }
    let filterBar = row(
      [
        searchBox, branchPopup, userPopup, datePopup,
        moreFilters,
        ActionButton(symbol: "arrow.clockwise", tooltip: "Refresh", size: 26) { [weak self] in self?.refresh()
        },
        ActionButton(symbol: "scissors", tooltip: "Cherry-Pick", size: 26) { [weak self] in
          self?.commitAction("cherry-pick")
        },
        logOptions,
        ActionButton(symbol: "magnifyingglass", tooltip: "Go to Hash/Branch/Tag (⌘F)", size: 26) {
          [weak self] in self?.goTo()
        },
      ], spacing: 3)
    configureTable(logTable)
    logTable.rowHeight = 26
    logTable.dataSource = self
    logTable.delegate = self
    logTable.allowsMultipleSelection = true
    logTable.setAccessibilityLabel("Git log")
    for (id, width) in [("graph", 44.0), ("subject", 390), ("author", 90), ("date", 126)] {
      let column = NSTableColumn(identifier: .init(id))
      column.width = width
      column.minWidth = id == "graph" ? 30 : (id == "subject" ? 100 : 70)
      column.resizingMask = []
      if id == "author" || id == "date" {
        column.isHidden = UserDefaults.standard.bool(forKey: "logHideColumn." + id)
      }
      logTable.addTableColumn(column)
    }
    logTable.columnAutoresizingStyle = .noColumnAutoresizing
    logTable.menuProvider = { [weak self] in self?.commitContextMenu() ?? NSMenu() }
    logTable.target = self
    logTable.doubleAction = nil
    logTable.onNearBottom = { [weak self] in self?.loadMoreHistory() }
    let logArea = Surface()
    pin(scrollView(logTable), to: logArea)
    let empty = NSStackView(views: [emptyLabel, emptyAction])
    empty.orientation = .vertical
    empty.spacing = 6
    empty.translatesAutoresizingMaskIntoConstraints = false
    logArea.addSubview(empty)
    NSLayoutConstraint.activate([
      empty.centerXAnchor.constraint(equalTo: logArea.centerXAnchor),
      empty.topAnchor.constraint(equalTo: logArea.topAnchor, constant: 65),
    ])
    emptyAction.contentTintColor = Theme.blue
    emptyAction.handler = { [weak self] in
      self?.repository == nil ? self?.openPanel() : self?.setMode("Commit")
    }
    emptyLabel.identifier = .init("EmptyLog")
    split.addArrangedSubview(makePanel(filterBar, body: logArea, height: 34))
    configureTable(filesTable)
    filesTable.allowsMultipleSelection = true
    filesTable.dataSource = self
    filesTable.delegate = self
    filesTable.addTableColumn(NSTableColumn(identifier: .init("file")))
    filesTable.outlineTableColumn = filesTable.tableColumns.first
    filesTable.indentationPerLevel = 13
    filesTable.target = self
    filesTable.doubleAction = #selector(showDiff)
    filesTable.previewSelection = { [weak self] in
      guard let self, !self.selectedDetailFiles.isEmpty else { return }
      self.showDiff()
    }
    filesTable.setAccessibilityLabel("Commit changes")
    filesTable.menuProvider = { [weak self] in self?.fileContextMenu(working: false) ?? NSMenu() }
    filesTable.toggleGrouping = { [weak self] directory in
      guard let self else { return }
      if directory { self.groupDetailDirectories.toggle() } else { self.groupDetailModules.toggle() }
      self.rebuildDetailFiles()
    }
    let detailOptions = ActionButton(symbol: "eye", tooltip: "View Options") {}
    detailOptions.handler = { [weak self, weak detailOptions] in self?.detailsOptions(anchor: detailOptions) }
    let fileBar = row(
      [
        ActionButton(symbol: "arrow.left.arrow.right", tooltip: "Show Diff (⌘D / Space)") { [weak self] in
          self?.showDiff()
        },
        ActionButton(symbol: "arrow.uturn.backward", tooltip: "Revert Commit") { [weak self] in
          self?.commitAction("revert")
        }, NSView(),
        detailOptions,
        ActionButton(symbol: "chevron.down", tooltip: "Expand All") { [weak self] in
          self?.filesTable.expandItem(nil, expandChildren: true)
        },
        ActionButton(symbol: "chevron.up", tooltip: "Collapse All") { [weak self] in
          self?.filesTable.collapseItem(nil, collapseChildren: true)
        },
      ], spacing: 4)
    let right = GitSplitView()
    detailsSplit = right
    right.isVertical = false
    right.dividerStyle = .thin
    right.autosaveName = "DetailsSplit"
    let filesArea = Surface()
    pin(scrollView(filesTable), to: filesArea)
    fileEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
    filesArea.addSubview(fileEmptyLabel)
    NSLayoutConstraint.activate([
      fileEmptyLabel.centerXAnchor.constraint(equalTo: filesArea.centerXAnchor),
      fileEmptyLabel.centerYAnchor.constraint(equalTo: filesArea.centerYAnchor),
    ])
    right.addArrangedSubview(makePanel(fileBar, body: filesArea, height: 34))
    detailsText.isEditable = false
    detailsText.isSelectable = true
    detailsText.drawsBackground = true
    detailsText.backgroundColor = Theme.background
    detailsText.textColor = Theme.text
    detailsText.font = Theme.font
    detailsText.linkTextAttributes = [.foregroundColor: Theme.blue]
    detailsText.textContainerInset = NSSize(width: 15, height: 12)
    detailsText.autoresizingMask = [.width]
    detailsText.isHorizontallyResizable = false
    detailsText.textContainer?.widthTracksTextView = true
    let detailArea = Surface()
    pin(scrollView(detailsText), to: detailArea)
    detailEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
    detailArea.addSubview(detailEmptyLabel)
    NSLayoutConstraint.activate([
      detailEmptyLabel.centerXAnchor.constraint(equalTo: detailArea.centerXAnchor),
      detailEmptyLabel.centerYAnchor.constraint(equalTo: detailArea.centerYAnchor),
    ])
    detailTextArea = detailArea
    right.addArrangedSubview(detailArea)
    updateDetailVisibility()
    split.addArrangedSubview(right)
    pin(split, to: logBody)
  }
  func buildConsole() {
    consoleText.isEditable = false
    consoleText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    consoleText.textColor = Theme.text
    consoleText.backgroundColor = Theme.background
    consoleText.textContainerInset = NSSize(width: 14, height: 12)
    pin(
      makePanel(
        row([
          label("Git Console", bold: true), NSView(),
          ActionButton("Clear") { [weak self] in self?.consoleText.string = "" },
        ]), body: scrollView(consoleText)), to: consoleBody)
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    if !initializedLayout {
      detailsSplit?.setPosition((detailsSplit?.bounds.height ?? 600) * 0.64, ofDividerAt: 0)
      initializedLayout = true
    }
    if split.subviews.count == 3 && split.subviews[0].frame.width < 100 {
      split.setPosition(split.bounds.width * 0.30, ofDividerAt: 0)
      split.setPosition(split.bounds.width * 0.78, ofDividerAt: 1)
    }
    if let workingSplit = commitBody.subviews.first as? NSSplitView {
      workingSplit.setPosition(440, ofDividerAt: 0)
    }
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    logTable.fitColumns()
    layoutCommitComposition()
  }
  func splitView(
    _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat { dividerIndex == 0 ? 180 : splitView.subviews[0].frame.width + 370 }
  func splitView(
    _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat { splitView.bounds.width - (dividerIndex == 0 ? 600 : 230) }
  func setMode(_ mode: String) {
    self.mode = mode
    sectionTitle.stringValue = mode == "Commit" ? "Commit" : "Git"
    if mode == "Commit" { layoutCommitComposition() }
    logBody.isHidden = mode != "Log"
    commitBody.isHidden = mode != "Commit"
    consoleBody.isHidden = mode != "Console"
    terminalBody.isHidden = mode != "Terminal"
    hostingBody.isHidden = mode != "Reviews"
    if mode == "Terminal" { terminalWorkspace.activate(at: repository?.workingDirectory) }
    if mode == "Reviews" { hostingWorkspace.configure(repository: repository) }
    for (name, button) in [("Log", logTab), ("Console", consoleTab), ("Commit", commitTab), ("Terminal", terminalTab), ("Reviews", hostingTab)] {
      button?.contentTintColor = mode == name ? Theme.blue : Theme.text
      button?.isBordered = mode == name
    }
  }
  func appendConsole(_ command: String, output: String, status: Int32) {
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss"
    let text =
      "[\(stamp.string(from: Date()))] \(ConsoleTextView.preview(command, limit: 2048))\n" + output
      + (output.hasSuffix("\n") || output.isEmpty ? "" : "\n")
      + (status == 0 ? "" : "Exit code: \(status)\n") + "\n"
    consoleText.appendEntry(text, attributes: [
      .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
      .foregroundColor: status == 0 ? Theme.text : Theme.red,
    ])
  }
  func open(_ url: URL) {
    guard !isBusy else { return }
    guard !hostingWorkspace.isWriting else { statusLabel.stringValue = "Wait for the hosting operation to finish before switching repositories."; return }
    amend.state = .off
    amendChanged()
    epoch += 1
    invalidateHistoryPage()
    loadedLogFilter = nil
    let currentEpoch = epoch
    consoleText.string = ""
    inlineDiff?.clear()
    loadedDetailHash = nil
    pendingDiffHash = nil
    selectedCommit = nil
    historyPresentation = nil
    logTable.deselectAll(nil)
    displayedLogCommits = []
    if let scroll = logTable.enclosingScrollView {
      scroll.contentView.scroll(to: .zero)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    comparison = nil
    detailToken += 1
    allAuthors = []
    branchesLoaded = false
    branchExpansionState = [:]
    selectedPaths = []
    ignoredPaths = []
    commitModules = []
    collapsedChanges = []
    commitAuthor = ""
    commitSignOff = false
    filter = LogFilter()
    filter.limit = historyPageSize
    let openingFilter = filter
    logSearch.stringValue = ""
    branchSearch.stringValue = ""
    datePopup.selectItem(at: 0)
    isBusy = true
    progress.startAnimation(nil)
    statusLabel.stringValue = "Opening \(url.lastPathComponent)…"
    let showLongEdges = showLongGraphEdges
    let showIgnored = showIgnoredFiles
    queue.async { [weak self] in
      do {
        let repo = try GitRepository(url: url)
        repo.onCommand = { [weak self] cmd, output, code in
          let preview = ConsoleTextView.preview(output)
          DispatchQueue.main.async {
            guard let self, self.epoch == currentEpoch else { return }
            self.appendConsole(cmd, output: preview, status: code)
          }
        }
        let data = try repo.snapshot(filter: openingFilter)
        let presentation = RepositoryHistoryPresentation.prepare(data, showLongEdges: showLongEdges)
        let ignored = showIgnored ? try repo.ignoredPaths() : []
        let modules = CommitModule.discover(in: repo.workingDirectory)
        let userEmail = (try? repo.run(["config", "user.email"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        DispatchQueue.main.async {
          guard let self, self.epoch == currentEpoch else { return }
          self.repository = repo
          self.terminalWorkspace.repositoryURL = repo.workingDirectory
          if self.mode == "Terminal" { self.terminalWorkspace.activate(at: repo.workingDirectory) }
          if self.mode == "Reviews" { self.hostingWorkspace.configure(repository: repo) }
          self.loadedLogFilter = openingFilter
          self.snapshot = data
          self.ignoredPaths = self.showIgnoredFiles ? ignored : []
          self.commitModules = modules
          self.currentUserEmail = userEmail
          self.isBusy = false
          self.progress.stopAnimation(nil)
          self.view.window?.title = repo.workingDirectory.lastPathComponent + " — GitDesk"
          self.repoLabel.title = repo.workingDirectory.lastPathComponent
          let color = ProjectIdentity.color(for: repo.workingDirectory)
          self.repoLabel.projectColor = color
          self.repositoryHeader.projectColor = color
          var recent = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
          recent.removeAll { $0 == repo.workingDirectory.path }
          recent.insert(repo.workingDirectory.path, at: 0)
          UserDefaults.standard.set(Array(recent.prefix(10)), forKey: "recentRepositories")
          UserDefaults.standard.set(repo.workingDirectory.path, forKey: "lastRepository")
          self.updateUI(presentation: presentation)
          self.setMode("Log")
        }
      } catch {
        DispatchQueue.main.async {
          self?.isBusy = false
          self?.progress.stopAnimation(nil)
          self?.showError(error)
        }
      }
    }
  }
  func refresh(silent: Bool = false, logOnly: Bool = false) {
    guard let repo = repository, !isBusy else { return }
    invalidateHistoryPage()
    if let loadedLogFilter, !filter.hasSameCriteria(as: loadedLogFilter) {
      filter.limit = historyPageSize
    }
    if isRefreshing {
      loadToken += 1
      pendingRefresh = true
      pendingRefreshLogOnly = pendingRefreshLogOnly && logOnly
      return
    }
    isRefreshing = true
    pendingRefreshLogOnly = logOnly
    loadToken += 1
    let token = loadToken
    let currentEpoch = epoch
    let filter = self.filter
    let previous = logOnly ? snapshot : nil
    let showLongEdges = showLongGraphEdges
    let showIgnored = showIgnoredFiles
    let previousIgnored = ignoredPaths
    let previousModules = commitModules
    let priorSnapshot = snapshot
    let priorPresentation = historyPresentation
    if !silent {
      progress.startAnimation(nil)
      statusLabel.stringValue = "Refreshing…"
    }
    queue.async { [weak self] in
      do {
        let data: RepositorySnapshot
        if let previous {
          data = try repo.filteredSnapshot(from: previous, filter: filter)
        } else {
          data = try repo.snapshot(filter: filter)
        }
        let ignored = previous != nil ? previousIgnored : (showIgnored ? try repo.ignoredPaths() : [])
        let modules = previous != nil ? previousModules : CommitModule.discover(in: repo.workingDirectory)
        let changed = priorSnapshot != data || previousIgnored != ignored || previousModules != modules
        let presentation = RepositoryHistoryPresentation.prepare(data, reusing: priorPresentation, showLongEdges: showLongEdges)
        DispatchQueue.main.async {
          guard let self else { return }
          self.isRefreshing = false
          self.progress.stopAnimation(nil)
          if self.loadToken == token && self.epoch == currentEpoch {
            if let loaded = self.loadedLogFilter,
              !filter.hasSameCriteria(as: loaded) || filter.limit < loaded.limit,
              let scroll = self.logTable.enclosingScrollView {
              // A new result set starts at the top. Keeping an old bottom
              // position could immediately request several unintended pages.
              scroll.contentView.scroll(to: .zero)
              scroll.reflectScrolledClipView(scroll.contentView)
            }
            self.loadedLogFilter = filter
            if changed {
              let modulesChanged = previousModules != modules
              self.snapshot = data
              self.ignoredPaths = self.showIgnoredFiles ? ignored : []
              self.commitModules = modules
              self.updateUI(previous: priorSnapshot, detailModulesChanged: modulesChanged, presentation: presentation)
            } else {
              self.updateStatus()
            }
            // A branch filter can change highlight policy without changing any
            // commit rows (for example All -> main). Refresh only appearance.
            if self.displayedCurrentBranchHighlight != self.shouldHighlightCurrentBranch {
              self.reloadLogAppearance()
            }
          }
          if self.pendingRefresh {
            let logOnly = self.pendingRefreshLogOnly
            self.pendingRefresh = false
            self.pendingRefreshLogOnly = true
            self.refresh(silent: true, logOnly: logOnly)
          }
        }
      } catch {
        DispatchQueue.main.async {
          guard let self else { return }
          self.isRefreshing = false
          self.progress.stopAnimation(nil)
          if self.loadToken == token && self.epoch == currentEpoch {
            self.statusLabel.stringValue = error.localizedDescription
            if !silent { self.showError(error) }
          }
          if self.pendingRefresh {
            let logOnly = self.pendingRefreshLogOnly
            self.pendingRefresh = false
            self.pendingRefreshLogOnly = true
            self.refresh(silent: true, logOnly: logOnly)
          }
        }
      }
    }
  }
  func perform(
    _ title: String, work: @escaping (GitRepository) throws -> Void, completion: (() -> Void)? = nil
  ) {
    guard let repo = repository, !isBusy else { return }
    invalidateHistoryPage()
    isBusy = true
    commitMessage.isEditable = false
    loadToken += 1
    progress.startAnimation(nil)
    statusLabel.stringValue = title + "…"
    commitButton.isEnabled = false
    queue.async { [weak self] in
      var failure: Error?
      do { try work(repo) } catch { failure = error }
      DispatchQueue.main.async {
        guard let self else { return }
        self.isBusy = false
        self.commitMessage.isEditable = true
        self.commitButton.isEnabled = true
        self.progress.stopAnimation(nil)
        if let failure { self.showError(failure) } else { completion?() }
        self.refresh()
      }
    }
  }
  func updateUI(previous: RepositorySnapshot? = nil, detailModulesChanged: Bool = false,
    presentation: RepositoryHistoryPresentation? = nil) {
    guard let data = snapshot else { return }
    operationControls.isHidden = data.operation == nil
    operationLabel.stringValue = (data.operation?.capitalized ?? "") + " in progress"
    operationControls.arrangedSubviews[3].isHidden = data.operation != "rebase"
    if let previous, previous.commits == data.commits, previous.history == data.history,
      previous.graphAncestry == data.graphAncestry, previous.branches == data.branches,
      previous.currentBranch == data.currentBranch {
      // Worktree, ignored-file, remote or stash changes cannot change log rows,
      // graph geometry or commit details. Preserve their views and selection.
      selectedPaths.formIntersection(Set(data.changes.map(\.path)))
      updateStatus()
      rebuildWorkingRows()
      if detailModulesChanged { rebuildDetailFiles() }
      return
    }
    let selectedHash = selectedCommit?.hash
    let selectedHashes = Set(logTable.selectedRowIndexes.compactMap { index in
      displayedLogCommits.indices.contains(index) ? displayedLogCommits[index].hash : nil
    })
    let prepared = presentation.flatMap { $0.showLongEdges == showLongGraphEdges ? $0 : nil }
      ?? RepositoryHistoryPresentation.prepare(data, reusing: historyPresentation, showLongEdges: showLongGraphEdges)
    assert(prepared.matches(data))
    historyPresentation = prepared
    graphs = prepared.graphs
    logTable.graphWidth = GraphCell.requiredWidth(lanes: min(10, CommitGraph.recommendedLaneCount(graphs)))
    logTable.authorWidth = min(140, max(80, data.commits.map {
      ($0.author as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 12
    }.max() ?? 80))
    currentBranchHistory = prepared.currentBranchHistory
    logTable.fitColumns()
    rebuildingLog = true
    displayedLogCommits = data.commits
    displayedCurrentBranchHighlight = shouldHighlightCurrentBranch
    logTable.reloadData()
    rebuildBranches()
    let hashes = selectedHashes.isEmpty ? Set(selectedHash.map { [$0] } ?? []) : selectedHashes
    let selection = IndexSet(data.commits.indices.filter { hashes.contains(data.commits[$0].hash) })
    logTable.selectRowIndexes(selection, byExtendingSelection: false)
    rebuildingLog = false
    if !selection.isEmpty {
      tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: logTable))
    } else {
      detailToken += 1
      loadedDetailHash = nil
      pendingDiffHash = nil
      selectedCommit = nil
      comparison = nil
      detailFiles = []
      rebuildDetailFiles()
      detailsText.string = ""
      detailEmptyLabel.isHidden = false
    }
    let branchSelection = filter.branch
    branchPopup.removeAllItems()
    branchPopup.addItem(withTitle: "Branch")
    branchPopup.addItem(withTitle: "HEAD (Current Branch)")
    for branch in data.branches {
      branchPopup.addItem(withTitle: branch.name)
      branchPopup.lastItem?.representedObject = branch.fullRef
    }
    branchPopup.item(at: 1)?.representedObject = "HEAD"
    if let branchSelection,
      let i = branchPopup.itemArray.firstIndex(where: {
        $0.representedObject as? String == branchSelection
      })
    {
      branchPopup.selectItem(at: i)
    } else if let branchSelection {
      branchPopup.addItem(withTitle: String(branchSelection.prefix(8)))
      branchPopup.lastItem?.representedObject = branchSelection
      branchPopup.selectItem(at: branchPopup.numberOfItems - 1)
    }
    let selectedAuthor = filter.author
    userPopup.removeAllItems()
    userPopup.addItem(withTitle: "User")
    allAuthors.formUnion(data.history.map(\.author))
    if let selectedAuthor { allAuthors.insert(selectedAuthor) }
    for author in allAuthors.sorted() { userPopup.addItem(withTitle: author) }
    if let selectedAuthor { userPopup.selectItem(withTitle: selectedAuthor) }
    branchLabel.title = data.currentBranch
    let available = Set(data.changes.map(\.path))
    selectedPaths.formIntersection(available)
    updateStatus()
    emptyLabel.superview?.isHidden = !data.commits.isEmpty
    if data.commits.isEmpty {
      emptyLabel.stringValue =
        filter.hasSameCriteria(as: LogFilter()) ? "No changes committed." : "No commits match your filters."
      emptyAction.title = "Commit local changes (⌘K)"
    }
    rebuildWorkingRows()
  }
  func updateStatus() {
    guard let data = snapshot else { return }
    statusLabel.stringValue =
      "\(repository?.workingDirectory.path ?? "")   ›   \(data.currentBranch)     \(data.commits.count) commits · \(data.changes.count) local changes"
      + (data.operation.map { "   ·   \($0) in progress" } ?? "")
  }
  func rebuildBranches() {
    guard let data = snapshot else { return }
    var previousSelection = Set<String>()
    func remember(_ nodes: [BranchNode], path: String = "") {
      for node in nodes {
        let key = path + "/" + node.title
        if branchOutline.selectedRowIndexes.contains(branchOutline.row(forItem: node)) {
          previousSelection.insert(node.branch?.fullRef ?? "group:" + key)
        }
        branchExpansionState[key] = branchOutline.isItemExpanded(node)
        remember(node.children, path: key)
      }
    }
    remember(branchNodes)
    let nodes = BranchTree.build(data.branches, favorites: favoriteRefs,
      search: branchSearch.stringValue, favoriteOnly: favoriteOnly,
      grouped: groupBranches, showTags: showTags)
    branchNodes = nodes
    branchOutline.reloadData()
    var selectedNodes: [BranchNode] = []
    func restore(_ nodes: [BranchNode], path: String = "") {
      for node in nodes {
        let key = path + "/" + node.title
        if previousSelection.contains(node.branch?.fullRef ?? "group:" + key) { selectedNodes.append(node) }
        if !branchesLoaded || branchExpansionState[key] ?? true { branchOutline.expandItem(node) }
        restore(node.children, path: key)
      }
    }
    restore(nodes)
    branchesLoaded = true
    branchOutline.deselectAll(nil)
    let selection = IndexSet(selectedNodes.map { branchOutline.row(forItem: $0) }.filter { $0 >= 0 })
    branchOutline.selectRowIndexes(selection, byExtendingSelection: false)
    branchOutline.fitContentWidth()
    if let clip = branchOutline.enclosingScrollView?.contentView {
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY))
      branchOutline.enclosingScrollView?.reflectScrolledClipView(clip)
    }
  }
  func controlTextDidChange(_ obj: Notification) {
    guard let field = obj.object as? NSSearchField else { return }
    if field == branchSearch {
      rebuildBranches()
      return
    }
    filter.text = logSearch.stringValue
    debounce?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.debounce = nil
      self?.refresh(logOnly: true)
    }
    debounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }
  @objc func branchFilterChanged() {
    filter.branch = branchPopup.selectedItem?.representedObject as? String
    refresh(logOnly: true)
  }
  @objc func userFilterChanged() {
    filter.author = userPopup.indexOfSelectedItem == 0 ? nil : userPopup.titleOfSelectedItem
    refresh(logOnly: true)
  }
  @objc func dateFilterChanged() {
    switch datePopup.indexOfSelectedItem {
    case 1: filter.since = "24 hours ago"
    case 2: filter.since = "7 days ago"
    case 3: filter.since = "30 days ago"
    case 4:
      if let dates = prompt(
        "Date Range", fields: [("Since (YYYY-MM-DD)", ""), ("Until (YYYY-MM-DD)", "")])
      {
        filter.since = dates[0].isEmpty ? nil : dates[0]
        filter.until = dates[1].isEmpty ? nil : dates[1]
      }
      refresh(logOnly: true)
      return
    default: filter.since = nil
    }
    filter.until = nil
    refresh(logOnly: true)
  }
  func numberOfRows(in tableView: NSTableView) -> Int {
    tableView == logTable
      ? snapshot?.commits.count ?? 0
      : tableView == changesTable ? workingRows.count : detailFiles.count
  }
  var shouldHighlightCurrentBranch: Bool {
    guard highlightCurrentBranch, let branch = snapshot?.currentBranch,
      branch != "Detached HEAD" else { return false }
    // IDEA suppresses this redundant background when the log is already
    // restricted to the checked-out branch or HEAD. Compare ref names, not
    // hashes: another branch/tag can point at the same commit.
    return filter.branch != "HEAD" && filter.branch != branch
      && filter.branch != "refs/heads/" + branch
  }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = SelectionRow()
    if tableView == logTable { view.isHovered = row == logTable.hoveredRow }
    view.usesInactiveColor = tableView != logTable && tableView != changesTable
    if tableView == logTable, shouldHighlightCurrentBranch,
      let commits = snapshot?.commits, row < commits.count,
      currentBranchHistory.contains(commits[row].hash) {
      view.backgroundTint = Theme.currentBranchBackground
    }
    return view
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int)
    -> NSView?
  {
    let id = tableColumn?.identifier.rawValue ?? ""
    if tableView == logTable {
      guard let data = snapshot, rowIndex < data.commits.count else { return nil }
      let commit = data.commits[rowIndex]
      if id == "graph" {
        let cell = GraphCell()
        cell.graph = graphs[rowIndex]
        cell.isHead = commit.decorations.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }
        return cell
      }
      if id == "subject" {
        let cell = LogSubjectCell()
        cell.compactReferences = compactReferences
        cell.showTagNames = showLogTagNames
        cell.referencesOnLeft = referencesOnLeft
        cell.dimMerge = highlightMergeCommits
        cell.graph = graphs[rowIndex]
        cell.graphColumnWidth = logTable.graphWidth
        cell.isHead = commit.decorations.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }
        cell.commit = commit
        return cell
      }
      if id == "author" {
        let cell = logMetadataCell(commit.author, color: highlightMergeCommits && commit.parents.count > 1 ? Theme.muted : Theme.text)
        if highlightMyCommits && !currentUserEmail.isEmpty && commit.email == currentUserEmail {
          cell.textField?.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        return cell
      }
      let cell = logMetadataCell(logDateFormatter.string(commit.date), color: highlightMergeCommits && commit.parents.count > 1 ? Theme.muted : Theme.text)
      cell.toolTip = logDateFormatter.absolute(commit.date)
      return cell
    }
    return workingCell(at: rowIndex)
  }
  /// Update existing date cells without reloading the graph, selection or files.
  func refreshLogDates(now: Date = Date()) {
    guard let dateColumn = logTable.tableColumns.firstIndex(where: { $0.identifier.rawValue == "date" }),
      let commits = snapshot?.commits else { return }
    let visible = logTable.rows(in: logTable.visibleRect)
    guard visible.location != NSNotFound, visible.length > 0 else { return }
    var changed = false
    for index in visible.location..<min(commits.count, visible.location + visible.length) {
      guard let cell = logTable.view(atColumn: dateColumn, row: index, makeIfNecessary: false) as? LogMetadataCell,
        let field = cell.textField else { continue }
      let text = logDateFormatter.string(commits[index].date, now: now)
      if field.stringValue != text { field.stringValue = text; changed = true }
      cell.toolTip = logDateFormatter.absolute(commits[index].date)
    }
    if changed { logTable.dismissTextExpansion() }
  }
  func cellText(_ text: String, color: NSColor = Theme.text, size: CGFloat = 13) -> NSTableCellView {
    let cell = NSTableCellView()
    let field = label(text, color: color, size: size)
    cell.textField = field
    pin(field, to: cell, inset: 5)
    return cell
  }
  private func logMetadataCell(_ text: String, color: NSColor) -> LogMetadataCell {
    let cell = LogMetadataCell()
    let field = label(text, color: color)
    field.usesSingleLineMode = true
    cell.textField = field
    pin(field, to: cell, inset: 5)
    return cell
  }
  func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
    tableView != logTable
  }
  @objc func checkFile(_ sender: NSButton) {
    guard sender.tag < workingRows.count else { return }
    let files = workingRows[sender.tag].files
    if files.allSatisfy({ selectedPaths.contains($0.path) }) {
      files.forEach { selectedPaths.remove($0.path) }
    } else {
      files.forEach { selectedPaths.insert($0.path) }
    }
    reloadWorkingCells()
  }
  func rebuildWorkingRows() {
    let selection = Set(changesTable.selectedRowIndexes.compactMap {
      workingRows.indices.contains($0) ? workingRows[$0].id : nil
    })
    workingRows = CommitChanges.rows(changes: snapshot?.changes ?? [],
      ignored: showIgnoredFiles ? ignoredPaths : [], modules: commitModules,
      directories: groupCommitDirectories, byModule: groupCommitModules, collapsed: collapsedChanges)
    changesTable.reloadData()
    let indices = workingRows.indices.filter { selection.contains(workingRows[$0].id) }
    changesTable.selectRowIndexes(IndexSet(indices.isEmpty ? [0] : indices), byExtendingSelection: false)
    updateCommitToolbar()
  }
  func rebuildDetailFiles() {
    let selection = Set(selectedDetailFiles.map(\.path))
    var expansion: [String: Bool] = [:]
    func remember(_ nodes: [FileNode]) {
      for node in nodes where !node.children.isEmpty {
        expansion[node.id] = filesTable.isItemExpanded(node)
        remember(node.children)
      }
    }
    remember(detailNodes)
    fileEmptyLabel.isHidden = !detailFiles.isEmpty
    fileEmptyLabel.stringValue = selectedCommit == nil && comparison == nil
      ? "Select commit to view changes" : "No changed files"
    detailNodes = DetailFiles.tree(detailFiles, modules: commitModules,
      directories: groupDetailDirectories, byModule: groupDetailModules)
    filesTable.reloadData()
    func restore(_ nodes: [FileNode]) {
      for node in nodes where !node.children.isEmpty {
        if expansion[node.id] ?? true { filesTable.expandItem(node) }
        restore(node.children)
      }
    }
    restore(detailNodes)
    let indices = (0..<filesTable.numberOfRows).filter { index in
      (filesTable.item(atRow: index) as? FileNode)?.file.map { selection.contains($0.path) }
        ?? false
    }
    filesTable.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
    if let clip = filesTable.enclosingScrollView?.contentView {
      clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY))
      filesTable.enclosingScrollView?.reflectScrolledClipView(clip)
    }
  }
  var selectedDetailFiles: [FileChange] {
    let paths = Set(filesTable.selectedRowIndexes.flatMap {
      (filesTable.item(atRow: $0) as? FileNode)?.files.map(\.path) ?? []
    })
    return detailFiles.filter { paths.contains($0.path) }
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard let table = notification.object as? NSTableView else { return }
    if table == logTable {
      guard !rebuildingLog else { return }
      let i = logTable.selectedRowIndexes.first ?? -1
      guard let commits = snapshot?.commits, i >= 0, i < commits.count else { return }
      selectedCommit = commits[i]
      comparison = nil
      loadDetails(commits[i])
    } else if table == changesTable {
      updateCommitToolbar()
      previewWorkingDiff()
    }
  }
  func loadDetails(_ commit: Commit) {
    guard let repo = repository else { return }
    detailToken += 1
    let token = detailToken
    if loadedDetailHash != commit.hash {
      detailFiles = []
      rebuildDetailFiles()
    }
    detailEmptyLabel.isHidden = true
    detailsText.textStorage?.setAttributedString(CommitDetails.text(for: commit))
    detailsText.scrollToBeginningOfDocument(nil)
    queue.async { [weak self] in
      do {
        let files = try repo.changes(in: commit)
        DispatchQueue.main.async {
          guard let self, self.detailToken == token else { return }
          self.loadedDetailHash = commit.hash
          self.detailFiles = files
          self.rebuildDetailFiles()
          if self.pendingDiffHash == commit.hash {
            self.pendingDiffHash = nil
            self.showDiff()
          }
        }
      } catch {
        DispatchQueue.main.async {
          guard let self, self.detailToken == token else { return }
          self.showError(error)
        }
      }
    }
  }
  func outlineViewSelectionDidChange(_ notification: Notification) {
    if notification.object as? NSOutlineView === branchOutline {
      branchDeleteButton?.isEnabled = !selectedBranches.isEmpty && !selectedBranches.contains(where: \.current)
      branchCompareButton?.isEnabled = selectedBranch.map { !$0.current } ?? false
      branchHeadButton?.isEnabled = selectedBranchRevision != nil
      branchFavoriteButton?.isEnabled = !selectedBranches.isEmpty
      branchFavoriteButton?.contentTintColor = !selectedBranches.isEmpty && selectedBranches.allSatisfy { favoriteRefs.contains($0.fullRef) }
        ? Theme.yellow : Theme.text
    }
  }
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if outlineView == filesTable { return (item as? FileNode)?.children.count ?? detailNodes.count }
    return (item as? BranchNode)?.children.count ?? branchNodes.count
  }
  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if outlineView == filesTable {
      return (item as? FileNode)?.children[index] ?? detailNodes[index]
    }
    return (item as? BranchNode)?.children[index] ?? branchNodes[index]
  }
  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    if let node = item as? FileNode { return !node.children.isEmpty }
    return !((item as? BranchNode)?.children.isEmpty ?? true)
  }
  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    if let node = item as? FileNode {
      let cell = NSTableCellView()
      let file = node.file
      let icon: NSImageView = file.map { FileTypeImageView(path: $0.path) }
        ?? NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")!)
      if file == nil { icon.contentTintColor = Theme.text }
      let color = file?.status == "Added" ? Theme.green
        : file?.status == "Deleted" ? Theme.red : file == nil ? Theme.text : Theme.blue
      let text = label(node.title, color: color)
      text.toolTip = file?.path
      icon.translatesAutoresizingMaskIntoConstraints = false
      icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
      icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
      var contents: [NSView] = [icon, text]
      if file == nil {
        contents.append(label("\(node.count) " + (node.count == 1 ? "file" : "files"), color: Theme.muted))
      }
      pin(row(contents, spacing: 6), to: cell, inset: 3)
      return cell
    }
    guard let node = item as? BranchNode else { return nil }
    let cell = BranchCell()
    let icon = cell.branchIcon
    if let branch = node.branch {
      switch BranchTree.icon(for: branch, favorites: favoriteRefs) {
      case .current:
        icon.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: "Current branch")
        icon.contentTintColor = Theme.yellow
      case .favorite:
        icon.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite " + branch.kind.rawValue)
        icon.contentTintColor = Theme.yellow
      case .tag:
        icon.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Tag")
        icon.contentTintColor = Theme.text
      case .branch:
        icon.image = Theme.branchIcon
        icon.contentTintColor = Theme.text
      }
    } else if !branchNodes.contains(node) {
      icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
    }
    let text = label(node.title, bold: node.branch?.current == true)
    cell.textField = text
    cell.toolTip = node.branch.map {
      $0.name + ($0.upstream.isEmpty ? "" : " → " + $0.upstream + " " + $0.tracking)
    }
    let stack =
      node.branch != nil || !branchNodes.contains(node)
      ? row([icon, text], spacing: 6) : row([text])
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
    pin(stack, to: cell, inset: 3)
    return cell
  }
  func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
    let row = SelectionRow()
    if outlineView === branchOutline {
      row.hoverColor = Theme.inactiveSelection
      row.isHovered = branchOutline.row(forItem: item) == branchOutline.hoveredRow
    }
    return row
  }
  var selectedBranches: [Branch] {
    branchOutline.selectedRowIndexes.compactMap {
      (branchOutline.item(atRow: $0) as? BranchNode)?.branch
    }
  }
  var selectedBranch: Branch? {
    guard branchOutline.selectedRowIndexes.count == 1 else { return nil }
    return selectedBranches.first
  }
  var selectedBranchRevision: String? {
    guard branchOutline.selectedRowIndexes.count == 1,
      let node = branchOutline.item(atRow: branchOutline.selectedRow) as? BranchNode else { return nil }
    return node.branch?.fullRef ?? (node.title == "HEAD (Current Branch)" ? "HEAD" : nil)
  }
  func navigateSelectedBranchHead() {
    guard let revision = selectedBranchRevision else { return }
    readHistory("Loading branch head", work: { try $0.commit(at: revision) }) { [weak self] commit in
      self?.revealHistoryCommit(commit)
    }
  }
  @objc func branchDoubleClick() {
    guard let node = branchOutline.item(atRow: branchOutline.clickedRow) as? BranchNode else {
      return
    }
    if let branch = node.branch {
      filter.branch = branch.fullRef
      refresh(logOnly: true)
    } else if node.title == "HEAD (Current Branch)" {
      filter.branch = "HEAD"
      refresh(logOnly: true)
    }
  }
  @objc func showDiff() {
    if mode == "Commit" {
      showWorkingDiff()
      return
    }
    guard selectedCommit != nil || comparison != nil else { return }
    if comparison == nil, let commit = selectedCommit, loadedDetailHash != commit.hash {
      pendingDiffHash = commit.hash
      return
    }
    let commit = selectedCommit
    let i =
      selectedDetailFiles.first.flatMap { file in detailFiles.firstIndex { $0.path == file.path } }
      ?? 0
    guard i < detailFiles.count else { return }
    let selected = selectedDetailFiles
    let files = selected.count > 1 ? selected : detailFiles
    openDiff(files: files, index: selected.count > 1 ? 0 : i, commit: commit, comparison: comparison)
  }
  @objc func showWorkingDiff() {
    let files = snapshot?.changes ?? []
    guard !workingSelection().isEmpty else { return }
    let i =
      workingSelection().first.flatMap { file in files.firstIndex { $0.path == file.path } } ?? 0
    guard i < files.count else { return }
    let selected = workingSelection()
    openDiff(files: selected.count > 1 ? selected : files, index: selected.count > 1 ? 0 : i)
  }
  func openDiff(
    files: [FileChange], index: Int, commit: Commit? = nil, comparison: (String, String)? = nil
  ) {
    guard let repository else { return }
    let diff = DiffWindowController(
      repository: repository, files: files, index: index, commit: commit, comparison: comparison)
    diffWindows.append(diff)
    diff.showWindow(nil)
    diff.onClose = { [weak self, weak diff] in self?.diffWindows.removeAll { $0 === diff } }
  }
  var inlineDiff: DiffViewController?
  func previewWorkingDiff() {
    if workingRows.indices.contains(changesTable.selectedRow),
      workingRows[changesTable.selectedRow].files.isEmpty {
      inlineDiff?.clear()
      return
    }
    guard let repo = repository, changesTable.selectedRow >= 0,
      changesTable.selectedRow < workingRows.count,
      let file = workingRows[changesTable.selectedRow].file,
      let workingSplit = commitBody.subviews.first as? NSSplitView
    else { return }
    if inlineDiff == nil {
      let controller = DiffViewController()
      controller.previousFile = { [weak self] in self?.navigateWorkingDiff(-1) }
      controller.nextFile = { [weak self] in self?.navigateWorkingDiff(1) }
      inlineDiff = controller
      let old = workingSplit.subviews[1]
      workingSplit.removeArrangedSubview(old)
      old.removeFromSuperview()
      workingSplit.addArrangedSubview(controller.view)
    }
    inlineDiff?.load(repository: repo, change: file)
  }
  func navigateWorkingDiff(_ delta: Int) {
    guard let files = snapshot?.changes, !files.isEmpty,
      let current = files.firstIndex(where: { $0.path == inlineDiff?.titleLabel.stringValue }) else { return }
    let next = min(max(current + delta, 0), files.count - 1)
    if !workingRows.contains(where: { $0.file?.path == files[next].path }) {
      collapsedChanges = []
      rebuildWorkingRows()
    }
    if let row = workingRows.firstIndex(where: { $0.file?.path == files[next].path }) {
      changesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      changesTable.scrollRowToVisible(row)
    }
  }
  func showError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Git operation failed"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
  func confirm(_ title: String, message: String, action: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
  func prompt(_ title: String, fields: [(String, String)], extra: NSView? = nil) -> [String]? {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    var inputs: [NSTextField] = []
    for (name, value) in fields {
      stack.addArrangedSubview(label(name))
      let input = NSTextField(string: value)
      input.setAccessibilityLabel(name)
      input.widthAnchor.constraint(equalToConstant: 350).isActive = true
      stack.addArrangedSubview(input)
      inputs.append(input)
    }
    if let extra { stack.addArrangedSubview(extra) }
    stack.frame = NSRect(
      x: 0, y: 0, width: 350, height: CGFloat(fields.count) * 55 + (extra == nil ? 0 : 32))
    alert.accessoryView = stack
    alert.window.initialFirstResponder = inputs.first
    return alert.runModal() == .alertFirstButtonReturn ? inputs.map(\.stringValue) : nil
  }
  func popup(_ menu: NSMenu, anchor: NSView? = nil) {
    menu.autoenablesItems = false
    if let anchor {
      let y = anchor.isFlipped ? anchor.bounds.maxY + 3 : anchor.bounds.minY - 3
      menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: y), in: anchor)
      return
    }
    var location = NSPoint(x: 20, y: view.bounds.height - 45)
    if let window = view.window, NSApp.currentEvent?.type != .keyDown {
      let mouse = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
      if view.bounds.contains(mouse) { location = mouse }
    }
    menu.popUp(positioning: nil, at: location, in: view)
  }
}
