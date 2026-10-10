import AppKit
import GitDeskCore

final class BranchNode: NSObject {
  var title: String
  var branch: Branch?
  var children: [BranchNode] = []
  init(_ title: String, branch: Branch? = nil) {
    self.title = title
    self.branch = branch
  }
}
final class FileNode: NSObject {
  let title: String
  var file: FileChange?
  var children: [FileNode] = []
  init(_ title: String, file: FileChange? = nil) {
    self.title = title
    self.file = file
  }
  var files: [FileChange] { file.map { [$0] } ?? children.flatMap(\.files) }
}
enum WorkingRow {
  case group(String, [FileChange])
  case file(FileChange)
  var files: [FileChange] {
    switch self {
    case .group(_, let files): return files
    case .file(let file): return [file]
    }
  }
}
final class LogSubjectCell: NSView {
  var compactReferences = true
  var commit: Commit? {
    didSet {
      needsDisplay = true
      setAccessibilityLabel(commit?.subject)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let commit else { return }
    toolTip = commit.decorations.joined(separator: "\n")
    let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.text]
    var right = bounds.width - 8
    let refs = commit.decorations.filter { $0 != "HEAD" }
    let primary = refs.first { $0.hasPrefix("HEAD -> ") }
      ?? refs.first { !$0.hasPrefix("tag: ") } ?? refs.first
    let visible = compactReferences ? primary.map { [$0] } ?? [] : refs
    for name in visible.reversed() {
      let clean = name.replacingOccurrences(of: "HEAD -> ", with: "").replacingOccurrences(
        of: "tag: ", with: "")
      if clean == "HEAD" { continue }
      let color = name.hasPrefix("tag: ") || name.hasPrefix("HEAD -> ") ? Theme.yellow : Theme.green
      let stacked = compactReferences && (refs.count > 1 || name.hasPrefix("HEAD -> "))
      let iconWidth: CGFloat = stacked ? 22 : 17
      let width = min(210, (clean as NSString).size(withAttributes: attrs).width + iconWidth)
      if right - width < 70 { break }
      let rect = NSRect(x: right - width, y: 5, width: width, height: 18)
      if stacked {
        Theme.green.setStroke()
        let back = NSBezierPath()
        back.lineWidth = 1
        back.move(to: NSPoint(x: rect.minX + 7, y: 19))
        back.line(to: NSPoint(x: rect.minX, y: 12))
        back.line(to: NSPoint(x: rect.minX + 5, y: 7))
        back.stroke()
      }
      color.setStroke()
      let offset: CGFloat = stacked ? 5 : 0
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
      (clean as NSString).draw(
        in: NSRect(x: rect.minX + iconWidth, y: 6, width: width - iconWidth, height: 16),
        withAttributes: [.font: Theme.font, .foregroundColor: Theme.muted])
      right -= width + 5
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    (commit.subject as NSString).draw(
      in: NSRect(x: 5, y: 6, width: max(0, right - 10), height: 18),
      withAttributes: [.font: Theme.font, .foregroundColor: commit.parents.count > 1 ? Theme.muted : Theme.text, .paragraphStyle: paragraph])
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
  var displayGraphColors: [NSColor] = []
  var currentBranchHistory = Set<String>()
  var highlightCurrentBranch = true
  var currentUserEmail = ""
  var branchesLoaded = false
  var branchExpansionState: [String: Bool] = [:]
  var branchNodes: [BranchNode] = []
  var loadedDetailHash: String?
  var pendingDiffHash: String?
  var selectedCommit: Commit?
  var detailFiles: [FileChange] = []
  var detailNodes: [FileNode] = []
  var workingRows: [WorkingRow] = []
  var collapsedChanges = Set<String>()
  var comparison: (String, String)?
  var mode = "Log"
  var selectedPaths = Set<String>()
  let queue = DispatchQueue(label: "gitdesk.git", qos: .userInitiated)
  var epoch = 0, loadToken = 0, detailToken = 0
  var isBusy = false
  var isRefreshing = false
  var pendingRefresh = false
  var pendingRefreshLogOnly = true
  var debounce: DispatchWorkItem?
  var watcher: Timer?
  var conflictWindows: [ConflictWindowController] = []
  var diffWindows: [DiffWindowController] = []
  var revisionWindows: [RevisionBrowserWindowController] = []
  var operationControls: NSStackView!
  let operationLabel = label("Rebase paused", color: Theme.yellow, size: 12)
  let split = GitSplitView()
  let branchOutline = MenuOutline()
  let logTable = LogTable()
  let filesTable = MenuOutline()
  let changesTable = CommitChangesTable()
  let branchSearch = FlatSearchField(frame: .zero)
  let logSearch = FlatSearchField(frame: .zero)
  let statusLabel = label("Open a Git repository to begin", color: Theme.muted, size: 11)
  let repoLabel = HeaderMenuButton("GitDesk", kind: .repository)
  let branchLabel = HeaderMenuButton("No branch", kind: .branch)
  let repositoryHeader = RepositoryHeader()
  var headerControls: NSStackView!
  let fileEmptyLabel = label("Select commit to view changes", color: Theme.muted)
  let detailTitle = label("Commit details", color: Theme.muted)
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
  var mainBody = Surface()
  var logBody = Surface()
  var commitBody = Surface()
  var consoleBody = Surface()
  var branchPanel: NSView!
  var logTab: ActionButton!
  var consoleTab: ActionButton!
  var commitTab: ActionButton!
  var commitButton: ActionButton!
  var commitSections: GitSplitView!
  var commitCompositionInitialized = false
  var showCommitDirectories = UserDefaults.standard.object(forKey: "commitShowDirectories") as? Bool ?? true {
    didSet { UserDefaults.standard.set(showCommitDirectories, forKey: "commitShowDirectories") }
  }
  var showCommitStatuses = UserDefaults.standard.bool(forKey: "commitShowStatuses") {
    didSet { UserDefaults.standard.set(showCommitStatuses, forKey: "commitShowStatuses") }
  }
  var commitRollbackButton: ActionButton!
  var commitDiffButton: ActionButton!
  let sectionTitle = label("Git", bold: true)
  var lastConsole = ""
  var favoriteOnly = false
  var groupBranches = true
  var compactReferences = true
  var branchHidden = false
  var showTags = true
  var showDetails = true
  var historyLimit = 2000
  var detailsSplit: NSSplitView?
  var initializedLayout = false
  var favoriteRefs: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: "favoriteRefs") ?? ["refs/heads/main", "refs/heads/master"]) }
    set { UserDefaults.standard.set(Array(newValue), forKey: "favoriteRefs") }
  }
  override func loadView() {
    view = Surface(Theme.chrome)
    buildUI()
    watcher = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      guard let self, self.repository != nil, !self.isBusy, !self.isRefreshing, self.debounce == nil,
        self.view.window?.attachedSheet == nil, NSApp.modalWindow == nil
      else { return }
      self.refresh(silent: true)
    }
  }
  deinit { watcher?.invalidate() }
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
    mainBody.layer?.cornerRadius = 9
    mainBody.layer?.masksToBounds = true
    mainBody.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainBody)
    logTab = ActionButton("Log") { [weak self] in self?.setMode("Log") }
    consoleTab = ActionButton("Console") { [weak self] in self?.setMode("Console") }
    commitTab = ActionButton("Commit") { [weak self] in self?.setMode("Commit") }
    for tab in [logTab, consoleTab, commitTab] { tab?.isTab = true }
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
        sectionTitle, logTab, consoleTab, commitTab, tabSpacer, operationControls,
        ActionButton(symbol: "arrow.clockwise", tooltip: "Refresh (⌘R)") { [weak self] in
          self?.refresh()
        },
      ], spacing: 16)
    tabs.translatesAutoresizingMaskIntoConstraints = false
    mainBody.addSubview(tabs)
    buildLog()
    buildCommit()
    buildConsole()
    for body in [logBody, commitBody, consoleBody] {
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
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      header.topAnchor.constraint(equalTo: view.topAnchor),
      header.heightAnchor.constraint(equalToConstant: 42),
      mainBody.topAnchor.constraint(equalTo: header.bottomAnchor),
      mainBody.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      mainBody.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
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
    branchColumn.resizingMask = .autoresizingMask
    branchColumn.minWidth = 0
    branchOutline.addTableColumn(branchColumn)
    branchOutline.outlineTableColumn = branchColumn
    configureTable(branchOutline)
    branchOutline.rowHeight = 25
    branchOutline.indentationPerLevel = 18
    branchOutline.dataSource = self
    branchOutline.delegate = self
    branchOutline.target = self
    branchOutline.doubleAction = #selector(branchDoubleClick)
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
        "star", "Show Favorite Branches",
        { [weak self] in
          guard let self else { return }
          self.favoriteOnly.toggle()
          self.rebuildBranches()
        }
      ), ("scope", "Select Current Branch", { [weak self] in
        guard let self else { return }
        self.branchOutline.expandItem(nil, expandChildren: true)
        if let index = (0..<self.branchOutline.numberOfRows).first(where: {
          (self.branchOutline.item(atRow: $0) as? BranchNode)?.branch?.current == true
        }) {
          self.branchOutline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
          self.branchOutline.scrollRowToVisible(index)
        }
      }),
      ("gearshape", "Branch View Options", { [weak self] in self?.filterMenu() }),
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
      toolbarRail.addArrangedSubview(ActionButton(symbol: icon, tooltip: title, size: 26, action: action))
    }
    let branchSearchBar = row([branchSearch])
    branchSearch.widthAnchor.constraint(equalTo: branchSearchBar.widthAnchor).isActive = true
    let branchScroll = scrollView(branchOutline)
    branchScroll.hasHorizontalScroller = false
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
    searchBox.layer?.borderColor = Theme.line.cgColor
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
    let filterBar = row(
      [
        searchBox, branchPopup, userPopup, datePopup,
        ActionButton(symbol: "chevron.right", tooltip: "More Filters and View Options", size: 26) {
          [weak self] in self?.filterMenu()
        },
        ActionButton(symbol: "arrow.clockwise", tooltip: "Refresh", size: 26) { [weak self] in self?.refresh()
        },
        ActionButton(symbol: "scissors", tooltip: "Cherry-Pick", size: 26) { [weak self] in
          self?.commitAction("cherry-pick")
        },
        ActionButton(symbol: "eye", tooltip: "Log View Options", size: 26) { [weak self] in self?.filterMenu() },
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
      column.minWidth = id == "graph" ? 30 : 70
      column.resizingMask = []
      logTable.addTableColumn(column)
    }
    logTable.columnAutoresizingStyle = .noColumnAutoresizing
    logTable.menuProvider = { [weak self] in self?.commitContextMenu() ?? NSMenu() }
    logTable.target = self
    logTable.doubleAction = nil
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
    filesTable.dataSource = self
    filesTable.delegate = self
    filesTable.addTableColumn(NSTableColumn(identifier: .init("file")))
    filesTable.outlineTableColumn = filesTable.tableColumns.first
    filesTable.indentationPerLevel = 13
    filesTable.target = self
    filesTable.doubleAction = #selector(showDiff)
    filesTable.setAccessibilityLabel("Commit changes")
    filesTable.menuProvider = { [weak self] in self?.fileContextMenu(working: false) ?? NSMenu() }
    let fileBar = row(
      [
        ActionButton(symbol: "arrow.left.arrow.right", tooltip: "Show Diff (⌘D)") { [weak self] in
          self?.showDiff()
        },
        ActionButton(symbol: "arrow.uturn.backward", tooltip: "Revert Commit") { [weak self] in
          self?.commitAction("revert")
        }, NSView(),
        ActionButton(symbol: "eye", tooltip: "View Options") { [weak self] in self?.detailsOptions()
        },
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
    detailsText.textContainerInset = NSSize(width: 15, height: 12)
    detailsText.autoresizingMask = [.width]
    detailsText.isHorizontallyResizable = false
    detailsText.textContainer?.widthTracksTextView = true
    let detailArea = Surface()
    pin(makePanel(detailTitle, body: scrollView(detailsText), height: 33), to: detailArea)
    detailEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
    detailArea.addSubview(detailEmptyLabel)
    NSLayoutConstraint.activate([
      detailEmptyLabel.centerXAnchor.constraint(equalTo: detailArea.centerXAnchor),
      detailEmptyLabel.centerYAnchor.constraint(equalTo: detailArea.centerYAnchor),
    ])
    detailTitle.isHidden = true
    right.addArrangedSubview(detailArea)
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
    for (name, button) in [("Log", logTab), ("Console", consoleTab), ("Commit", commitTab)] {
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
    epoch += 1
    let currentEpoch = epoch
    consoleText.string = ""
    inlineDiff?.clear()
    loadedDetailHash = nil
    pendingDiffHash = nil
    selectedCommit = nil
    comparison = nil
    detailToken += 1
    allAuthors = []
    branchesLoaded = false
    branchExpansionState = [:]
    selectedPaths = []
    commitAuthor = ""
    commitSignOff = false
    filter = LogFilter()
    logSearch.stringValue = ""
    branchSearch.stringValue = ""
    datePopup.selectItem(at: 0)
    isBusy = true
    progress.startAnimation(nil)
    statusLabel.stringValue = "Opening \(url.lastPathComponent)…"
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
        let data = try repo.snapshot()
        let userEmail = (try? repo.run(["config", "user.email"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        DispatchQueue.main.async {
          guard let self, self.epoch == currentEpoch else { return }
          self.repository = repo
          self.snapshot = data
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
          self.updateUI()
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
        DispatchQueue.main.async {
          guard let self else { return }
          self.isRefreshing = false
          self.progress.stopAnimation(nil)
          if self.loadToken == token && self.epoch == currentEpoch {
            if self.snapshot != data {
              self.snapshot = data
              self.updateUI()
            } else {
              self.updateStatus()
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
  func updateUI() {
    guard let data = snapshot else { return }
    operationControls.isHidden = data.operation == nil
    operationLabel.stringValue = (data.operation?.capitalized ?? "") + " in progress"
    operationControls.arrangedSubviews[3].isHidden = data.operation != "rebase"
    let selectedHash = selectedCommit?.hash
    graphs = CommitGraph.layout(data.commits, ancestry: data.history)
    logTable.graphWidth = CGFloat(min(10, max(2, graphs.map(\.laneCount).max() ?? 2))) * 15 + 8
    logTable.authorWidth = min(140, max(80, data.commits.map {
      ($0.author as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 12
    }.max() ?? 80))
    // The checked-out tip has its own color until it joins the main branch.
    let ancestry = Dictionary(data.history.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
    currentBranchHistory = []
    let head = data.branches.first(where: \.current)?.hash ?? data.history.first {
      $0.decorations.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }
    }?.hash
    var pending = head.map { [$0] } ?? []
    while let hash = pending.popLast() {
      if currentBranchHistory.insert(hash).inserted { pending.append(contentsOf: ancestry[hash]?.parents ?? []) }
    }
    var mainHistory = Set<String>()
    var cursor = data.branches.first { $0.kind == .local && ["main", "master"].contains($0.name) }?.hash
    while let hash = cursor, mainHistory.insert(hash).inserted { cursor = ancestry[hash]?.parents.first }
    let historyGraphs = CommitGraph.layout(data.history)
    let historyColors = Dictionary(zip(data.history.map(\.hash), historyGraphs.map(\.color)), uniquingKeysWith: { first, _ in first })
    let mainGraphColor = data.history.first { mainHistory.contains($0.hash) }.flatMap { historyColors[$0.hash] }
    displayGraphColors = data.commits.enumerated().map { index, commit in
      let color = historyColors[commit.hash] ?? graphs[index].color
      if mainGraphColor == color { return mainHistory.contains(commit.hash) ? Theme.graph[0] : Theme.graph[4] }
      return Theme.graph[color % Theme.graph.count]
    }
    logTable.fitColumns()
    logTable.reloadData()
    rebuildBranches()
    if let selectedHash, let index = data.commits.firstIndex(where: { $0.hash == selectedHash }) {
      logTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      selectedCommit = nil
      detailFiles = []
      rebuildDetailFiles()
      detailsText.string = ""
      detailTitle.stringValue = "Commit details"
      detailTitle.isHidden = true
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
        filter == LogFilter() ? "No changes committed." : "No commits match your filters."
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
    let previousSelection = selectedBranch?.fullRef
    func remember(_ nodes: [BranchNode], path: String = "") {
      for node in nodes {
        let key = path + "/" + node.title
        branchExpansionState[key] = branchOutline.isItemExpanded(node)
        remember(node.children, path: key)
      }
    }
    remember(branchNodes)
    let search = branchSearch.stringValue
    var nodes = [BranchNode("HEAD (Current Branch)")]
    for (kind, title) in [(Branch.Kind.local, "Local"), (.remote, "Remote"), (.tag, "Tags")] {
      if kind == .tag && !showTags { continue }
      let group = BranchNode(title)
      let refs = data.branches.filter {
        $0.kind == kind && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
          && (!favoriteOnly || $0.current || favoriteRefs.contains($0.fullRef))
      }.sorted { a, b in
        let aFavorite = favoriteRefs.contains(a.fullRef), bFavorite = favoriteRefs.contains(b.fullRef)
        return aFavorite != bFavorite ? aFavorite : a.name.localizedStandardCompare(b.name) == .orderedAscending
      }
      for branch in refs {
        var parent = group
        let parts =
          groupBranches ? branch.name.split(separator: "/").map(String.init) : [branch.name]
        for part in parts.dropLast() {
          if let existing = parent.children.first(where: { $0.title == part && $0.branch == nil }) {
            parent = existing
          } else {
            let folder = BranchNode(part)
            parent.children.append(folder)
            parent = folder
          }
        }
        parent.children.append(BranchNode(parts.last ?? branch.name, branch: branch))
      }
      if !group.children.isEmpty { nodes.append(group) }
    }
    branchNodes = nodes
    branchOutline.reloadData()
    func restore(_ nodes: [BranchNode], path: String = "") {
      for node in nodes {
        let key = path + "/" + node.title
        if !branchesLoaded || branchExpansionState[key] ?? true { branchOutline.expandItem(node) }
        restore(node.children, path: key)
      }
    }
    restore(nodes)
    branchesLoaded = true
    branchOutline.deselectAll(nil)
    if let index = (0..<branchOutline.numberOfRows).first(where: {
      (branchOutline.item(atRow: $0) as? BranchNode)?.branch.map {
        $0.fullRef == previousSelection
      } == true
    }) {
      branchOutline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
    branchOutline.sizeLastColumnToFit()
    if let clip = branchOutline.enclosingScrollView?.contentView {
      clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY))
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
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = SelectionRow()
    view.usesInactiveColor = tableView != logTable && tableView != changesTable
    if tableView == changesTable { view.cornerRadius = 3 }
    if tableView == logTable, highlightCurrentBranch,
      let commits = snapshot?.commits, row < commits.count,
      currentBranchHistory.contains(commits[row].hash) {
      view.backgroundTint = Theme.selection
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
        cell.primaryColor = displayGraphColors[rowIndex]
        if rowIndex + 1 < graphs.count, graphs[rowIndex + 1].color == graphs[rowIndex].color {
          cell.outgoingColor = displayGraphColors[rowIndex + 1]
        }
        return cell
      }
      if id == "subject" {
        let cell = LogSubjectCell()
        cell.compactReferences = compactReferences
        cell.commit = commit
        return cell
      }
      if id == "author" {
        let cell = cellText(commit.author, color: commit.parents.count > 1 ? Theme.muted : Theme.text)
        if !currentUserEmail.isEmpty && commit.email == currentUserEmail {
          cell.textField?.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        return cell
      }
      let format = DateFormatter()
      format.locale = Locale(identifier: "en_US_POSIX")
      format.dateFormat = "yyyy/M/d HH:mm"
      return cellText(format.string(from: commit.date), color: commit.parents.count > 1 ? Theme.muted : Theme.text)
    }
    return workingCell(at: rowIndex)
  }
  func cellText(_ text: String, color: NSColor = Theme.text, size: CGFloat = 13) -> NSTableCellView {
    let cell = NSTableCellView()
    let field = label(text, color: color, size: size)
    cell.textField = field
    pin(field, to: cell, inset: 5)
    return cell
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
    let groups = Set(changesTable.selectedRowIndexes.compactMap { index -> String? in
      guard workingRows.indices.contains(index), case .group(let name, _) = workingRows[index] else { return nil }
      return name
    })
    let selection = Set(
      changesTable.selectedRowIndexes.flatMap { index in
        if workingRows.indices.contains(index), case .file(let file) = workingRows[index] { return [file.path] }
        return []
      })
    let files = snapshot?.changes ?? []
    workingRows = []
    for (name, group) in [
      ("Conflicts", files.filter(\.isConflicted)),
      ("Changes", files.filter { !$0.isUntracked && !$0.isConflicted }),
      ("Unversioned Files", files.filter(\.isUntracked)),
    ] where name == "Changes" || !group.isEmpty {
      workingRows.append(.group(name, group))
      if !collapsedChanges.contains(name) { workingRows += group.map(WorkingRow.file) }
    }
    changesTable.reloadData()
    let indices = workingRows.indices.filter { index in
      if case .file(let file) = workingRows[index] { return selection.contains(file.path) }
      if case .group(let name, _) = workingRows[index] { return groups.contains(name) }
      return false
    }
    changesTable.selectRowIndexes(IndexSet(indices.isEmpty ? [0] : indices), byExtendingSelection: false)
    updateCommitToolbar()
  }
  func rebuildDetailFiles() {
    let selection = Set(selectedDetailFiles.map(\.path))
    let root = FileNode(
      "\(repository?.workingDirectory.lastPathComponent ?? "Repository")  ·  \(detailFiles.count) files"
    )
    for file in detailFiles {
      var parent = root
      let parts = file.path.split(separator: "/").map(String.init)
      for part in parts.dropLast() {
        if let node = parent.children.first(where: { $0.title == part && $0.file == nil }) {
          parent = node
        } else {
          let node = FileNode(part)
          parent.children.append(node)
          parent = node
        }
      }
      parent.children.append(FileNode(parts.last ?? file.path, file: file))
    }
    fileEmptyLabel.isHidden = !detailFiles.isEmpty
    fileEmptyLabel.stringValue =
      selectedCommit == nil && comparison == nil
      ? "Select commit to view changes" : "No changed files"
    detailNodes = detailFiles.isEmpty ? [] : [root]
    filesTable.reloadData()
    filesTable.expandItem(nil, expandChildren: true)
    let indices = (0..<filesTable.numberOfRows).filter { index in
      (filesTable.item(atRow: index) as? FileNode)?.file.map { selection.contains($0.path) }
        ?? false
    }
    filesTable.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
  }
  var selectedDetailFiles: [FileChange] {
    filesTable.selectedRowIndexes.flatMap { (filesTable.item(atRow: $0) as? FileNode)?.files ?? [] }
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard let table = notification.object as? NSTableView else { return }
    if table == logTable {
      let i = logTable.selectedRow
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
    detailTitle.stringValue = commit.shortHash
    detailTitle.isHidden = false
    detailEmptyLabel.isHidden = true
    let detailMessage =
      commit.subject + "\n\n" + commit.body + "\n\n"
      + "\(commit.shortHash)  \(commit.author) <\(commit.email)>\n" + commit.date.formatted()
      + "\n\n" + commit.decorations.joined(separator: "   ") + "\n\nParents: "
      + commit.parents.map { String($0.prefix(8)) }.joined(separator: ", ")
    detailsText.textStorage?.setAttributedString(NSAttributedString(string: detailMessage,
      attributes: [.font: Theme.font, .foregroundColor: Theme.text]))
    let subjectRange = NSRange(location: 0, length: (commit.subject as NSString).length)
    detailsText.textStorage?.addAttributes(
      [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Theme.text],
      range: subjectRange)
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
      let icon = NSImageView()
      let file = node.file
      icon.image = NSImage(
        systemSymbolName: file == nil ? "folder" : "doc",
        accessibilityDescription: file?.status ?? "Folder")
      icon.contentTintColor =
        file?.status == "Added"
        ? Theme.green
        : file?.status == "Deleted" ? Theme.red : file == nil ? Theme.text : Theme.blue
      let text = label(node.title, color: icon.contentTintColor ?? Theme.text)
      text.toolTip = file?.path
      icon.translatesAutoresizingMaskIntoConstraints = false
      icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
      pin(row([icon, text]), to: cell, inset: 3)
      return cell
    }
    guard let node = item as? BranchNode else { return nil }
    let cell = NSTableCellView()
    let icon = NSImageView()
    if let branch = node.branch {
      icon.image = NSImage(
        systemSymbolName: favoriteRefs.contains(branch.fullRef) ? "star.fill"
          : branch.kind == .tag ? "tag" : "arrow.triangle.branch",
        accessibilityDescription: branch.kind.rawValue)
      icon.contentTintColor =
        favoriteRefs.contains(branch.fullRef) ? Theme.yellow : Theme.text
      if branch.kind != .tag && !favoriteRefs.contains(branch.fullRef) { icon.image = Theme.branchIcon }
    } else if !branchNodes.contains(node) {
      icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
    }
    let text = label(node.title, bold: node.branch?.current == true)
    text.toolTip = node.branch.map {
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
    SelectionRow()
  }
  var selectedBranch: Branch? {
    (branchOutline.item(atRow: branchOutline.selectedRow) as? BranchNode)?.branch
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
    openDiff(files: detailFiles, index: i, commit: commit, comparison: comparison)
  }
  @objc func showWorkingDiff() {
    let files = snapshot?.changes ?? []
    let i =
      workingSelection().first.flatMap { file in files.firstIndex { $0.path == file.path } } ?? 0
    guard i < files.count else { return }
    openDiff(files: files, index: i)
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
    guard let repo = repository, changesTable.selectedRow >= 0,
      changesTable.selectedRow < workingRows.count,
      case .file(let file) = workingRows[changesTable.selectedRow],
      let workingSplit = commitBody.subviews.first as? NSSplitView
    else { return }
    if inlineDiff == nil {
      let controller = DiffViewController()
      inlineDiff = controller
      let old = workingSplit.subviews[1]
      workingSplit.removeArrangedSubview(old)
      old.removeFromSuperview()
      workingSplit.addArrangedSubview(controller.view)
    }
    inlineDiff?.load(repository: repo, change: file)
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
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: anchor)
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
