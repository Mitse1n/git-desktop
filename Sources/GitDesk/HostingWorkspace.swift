import AppKit
import GitDeskCore

final class HostingWorkspace: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  private let remotePicker = NSPopUpButton()
  let search = FlatSearchField(frame: .zero)
  let requestsTable = HostingRequestTable()
  let filesTable = MenuTable()
  private let overview = NSTextView(), patch = NSTextView(), discussion = NSTextView(), checks = NSTextView()
  private let status = label("Open a repository with a GitHub or GitLab remote.", color: Theme.muted, size: 12)
  private let repositoryButton = ActionButton("Code Reviews") {}
  let listEmptyMessage = label("Open a repository with a GitHub or GitLab remote.", color: Theme.muted)
  private let listEmptyAction = ActionButton("Connect Account…", size: 20) {}
  private let listEmpty = NSStackView()
  private let rightContent = Surface()
  private var filterControls: [String: ReviewFilterControl] = [:]
  private(set) var requestFilter = HostedRequestFilter()
  private var listLoading = false
  private var listError: String?
  private var searchWork: DispatchWorkItem?
  private var scrollObserver: NSObjectProtocol?
  var detailsVisible: Bool { !rightContent.isHidden }

  let tabs = NSTabView()
  private let threadPicker = NSPopUpButton()
  private var threads: [HostedThread] = []
  private var sectionButtons: [ActionButton] = []
  let navigationSplit = NSSplitView()
  let requestList = Surface()
  let requestOverview = Surface()
  private let requestTitle = label("", bold: true)
  private let requestBranches = label("", color: Theme.blue, size: 12)
  private let requestAuthor = label("", color: Theme.muted, size: 12)
  private var initializedNavigation = false
  private var requests: [HostedRequest] = [], displayed: [HostedRequest] = [], files: [HostedFile] = []
  private var remotes: [(name: String, url: String)] = []
  var contextChanged: ((HostingProvider?) -> Void)?
  private(set) var context: HostingRepository? {
    didSet { contextChanged?(context?.provider) }
  }
  private var client: HostingClient?
  private var repo: GitRepository?
  private var page = 1, hasMore = false
  private var task: Task<Void, Never>?, detailTask: Task<Void, Never>?
  private var requestButtons: [String: ActionButton] = [:]
  private var writing = false { didSet { updateActionState() } }
  var isWriting: Bool { writing }
  private var detailReady = false { didSet { updateActionState() } }
  private var selected: HostedRequest?
  private var openedRequest: HostedRequest?
  private var selectOpenedButton: ToolWindowButton!
  private var quickFilterButton: ToolWindowButton?
  var hideToolWindow: (() -> Void)?
  var checkout: ((HostingRepository, HostedRequest) -> Void)?
  var showDiff: ((HostingRepository, HostedRequest, String?) -> Void)?
  deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }; task?.cancel(); detailTask?.cancel(); searchWork?.cancel() }
  override func loadView() {
    view = Surface()
    remotePicker.target = self; remotePicker.action = #selector(remoteChanged)
    search.placeholderString = ""; search.delegate = self
    search.setAccessibilityLabel("Search pull or merge requests")
    search.sendsSearchStringImmediately = true
    search.showsFocusOutline = true
    repositoryButton.isTab = true
    repositoryButton.isBordered = true
    repositoryButton.handler = { [weak self] in self?.repositoryMenu() }
    selectOpenedButton = ToolWindowButton(icon: "locate", tooltip: "Select Opened Request", size: 24, iconSize: 16) { [weak self] in self?.revealOpenedRequest() }
    selectOpenedButton.isEnabled = false
    let toolbar = row([repositoryButton, NSView(),
      ToolWindowButton(icon: "add", tooltip: "Create Request…", size: 24, iconSize: 16) { [weak self] in self?.createRequest() },
      selectOpenedButton,
      ToolWindowButton(icon: "moreVertical", tooltip: "Options", size: 24, iconSize: 16) { [weak self] in self?.listOptions() },
      ToolWindowButton(icon: "hide", tooltip: "Hide", size: 24, iconSize: 16) { [weak self] in self?.hideToolWindow?() }
    ], spacing: 2)
    toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 3)
    for table in [requestsTable, filesTable] {
      configureTable(table); table.delegate = self; table.dataSource = self; table.rowHeight = 48
      table.addTableColumn(NSTableColumn(identifier: .init("content")))
    }
    requestsTable.setAccessibilityLabel("Pull requests and merge requests")
    filesTable.setAccessibilityLabel("Changed files")
    filesTable.target = self; filesTable.doubleAction = #selector(openFileDiff)
    requestsTable.openRequest = { [weak self] in self?.openSelectedRequest() }
    requestsTable.target = self; requestsTable.doubleAction = #selector(openSelectedRequest)
    requestsTable.menuProvider = { [weak self] in self?.requestMenu() ?? NSMenu() }
    let list = Surface()
    let tableScroll = scrollView(requestsTable)
    tableScroll.contentView.postsBoundsChangedNotifications = true
    scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
      object: tableScroll.contentView, queue: .main) { [weak self, weak tableScroll] _ in
        guard let self, let tableScroll, self.hasMore, !self.listLoading,
          tableScroll.documentVisibleRect.maxY >= self.requestsTable.bounds.height - 120 else { return }
        self.reload(more: true)
      }
    pin(tableScroll, to: list)
    listEmpty.orientation = .vertical; listEmpty.alignment = .centerX; listEmpty.spacing = 2
    listEmptyMessage.maximumNumberOfLines = 3
    listEmptyMessage.alignment = .center
    listEmptyAction.contentTintColor = Theme.blue
    listEmptyAction.handler = { [weak self] in
      guard let self else { return }
      if self.listError != nil { self.reload() }
      else if self.client == nil { self.connect() }
      else { self.clearFilters() }
    }
    listEmpty.addArrangedSubview(listEmptyMessage); listEmpty.addArrangedSubview(listEmptyAction)
    listEmpty.translatesAutoresizingMaskIntoConstraints = false
    list.addSubview(listEmpty)
    let emptyTop = NSView(); emptyTop.translatesAutoresizingMaskIntoConstraints = false
    list.addSubview(emptyTop)
    NSLayoutConstraint.activate([
      emptyTop.topAnchor.constraint(equalTo: list.topAnchor),
      emptyTop.heightAnchor.constraint(equalTo: list.heightAnchor, multiplier: 1.0 / 3, constant: -14),
      emptyTop.leadingAnchor.constraint(equalTo: list.leadingAnchor),
      emptyTop.widthAnchor.constraint(equalToConstant: 0),
      listEmpty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
      listEmpty.topAnchor.constraint(equalTo: emptyTop.bottomAnchor),
      listEmpty.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -30),
    ])
    let filterBar = buildFilterBar()
    let searchArea = Surface()
    searchArea.addSubview(search); filterBar.translatesAutoresizingMaskIntoConstraints = false
    searchArea.addSubview(filterBar)
    NSLayoutConstraint.activate([
      search.leadingAnchor.constraint(equalTo: searchArea.leadingAnchor, constant: 2),
      search.trailingAnchor.constraint(equalTo: searchArea.trailingAnchor, constant: -2),
      search.topAnchor.constraint(equalTo: searchArea.topAnchor, constant: 11),
      filterBar.leadingAnchor.constraint(equalTo: searchArea.leadingAnchor, constant: 0),
      filterBar.trailingAnchor.constraint(equalTo: searchArea.trailingAnchor, constant: 0),
      filterBar.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
      filterBar.heightAnchor.constraint(equalToConstant: 30),
    ])
    pin(makePanel(searchArea, body: list, height: 86), to: requestList)
    for text in [overview, patch, discussion, checks] {
      text.isEditable = false; text.isRichText = false; text.font = Theme.font
      text.textColor = Theme.text; text.backgroundColor = Theme.background
      text.textContainerInset = NSSize(width: 14, height: 12)
    }
    patch.font = DiffFont.regular()
    filesTable.rowHeight = 28
    func tab(_ name: String, _ content: NSView) {
      let item = NSTabViewItem(identifier: name); item.label = name; item.view = content; tabs.addTabViewItem(item)
    }
    tab("Overview", scrollView(overview))
    tab("Files", scrollView(patch))
    let threadToolbar = row([label("Line discussion:"), threadPicker,
      ActionButton("Reply…") { [weak self] in self?.replyToThread() },
      ActionButton("Resolve / Unresolve") { [weak self] in self?.resolveThread() }, NSView()])
    tab("Timeline", makePanel(threadToolbar, body: scrollView(discussion)))
    tab("Checks & Reviews", scrollView(checks))
    let checkout = ActionButton("Check Out") { [weak self] in self?.checkOut() }
    let diff = ActionButton("Show Diff") { [weak self] in self?.openFullDiff() }
    let comment = ActionButton("Comment…") { [weak self] in self?.sendComment() }
    let review = ActionButton("Review…") { [weak self] in self?.reviewMenu() }
    let merge = ActionButton("Merge…") { [weak self] in self?.mergeMenu() }
    let close = ActionButton("Close / Reopen…") { [weak self] in self?.changeState() }
    for button in [checkout, diff, comment, review, merge, close] { requestButtons[button.title] = button }
    requestTitle.lineBreakMode = .byTruncatingTail
    requestTitle.usesSingleLineMode = true
    let summary = NSStackView(views: [
      row([ActionButton("All Requests", symbol: "chevron.left") { [weak self] in self?.showRequestList() }, NSView(),
        ActionButton(symbol: "arrow.up.right.square", tooltip: "Open on Server") { [weak self] in self?.openBrowser() }]),
      requestTitle, requestAuthor, requestBranches,
      row([checkout, diff, NSView()]), row([review, merge, close, NSView()]), row([comment, NSView()]), status])
    summary.orientation = .vertical; summary.alignment = .leading; summary.spacing = 6
    summary.translatesAutoresizingMaskIntoConstraints = false
    let changedFiles = makePanel(row([label("Changes", bold: true), NSView()]), body: scrollView(filesTable), height: 32)
    changedFiles.translatesAutoresizingMaskIntoConstraints = false
    requestOverview.addSubview(summary); requestOverview.addSubview(changedFiles)
    NSLayoutConstraint.activate([
      summary.topAnchor.constraint(equalTo: requestOverview.topAnchor, constant: 6),
      summary.leadingAnchor.constraint(equalTo: requestOverview.leadingAnchor, constant: 12),
      summary.trailingAnchor.constraint(equalTo: requestOverview.trailingAnchor, constant: -12),
      changedFiles.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
      changedFiles.leadingAnchor.constraint(equalTo: requestOverview.leadingAnchor),
      changedFiles.trailingAnchor.constraint(equalTo: requestOverview.trailingAnchor),
      changedFiles.bottomAnchor.constraint(equalTo: requestOverview.bottomAnchor),
    ])
    let navigation = Surface()
    for panel in [requestList, requestOverview] { pin(panel, to: navigation) }
    showRequestList()
    status.maximumNumberOfLines = 2
    status.lineBreakMode = .byTruncatingMiddle
    let left = makePanel(toolbar, body: navigation, height: 40, inset: 4)
    left.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
    left.widthAnchor.constraint(lessThanOrEqualToConstant: 700).isActive = true
    tabs.tabViewType = .noTabsNoBorder
    sectionButtons = ["Overview", "Files", "Timeline", "Checks & Reviews"].enumerated().map { index, title in
      let button = ActionButton(title) { [weak self] in self?.selectSection(index) }
      button.isTab = true
      return button
    }
    let sections = row(sectionButtons + [NSView()], spacing: 14)
    pin(makePanel(sections, body: tabs, height: 36), to: rightContent)
    navigationSplit.isVertical = true; navigationSplit.dividerStyle = .thin
    navigationSplit.autosaveName = "ReviewToolWindowSplit"
    let editorArea = Surface()
    pin(rightContent, to: editorArea)
    navigationSplit.addArrangedSubview(left); navigationSplit.addArrangedSubview(editorArea)
    pin(navigationSplit, to: view)
    updateActionState()
    overview.string = "Select a request to view its description, changed files, discussion, reviews and CI checks."
    selectSection(0)
    updateListState()
  }
  func selectSection(_ index: Int) {
    tabs.selectTabViewItem(at: index)
    for (position, button) in sectionButtons.enumerated() {
      button.contentTintColor = position == index ? Theme.blue : Theme.text
      button.isBordered = position == index
    }
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    if !initializedNavigation, navigationSplit.bounds.width > 600 {
      initializedNavigation = true
      navigationSplit.setPosition(580, ofDividerAt: 0)
    }
  }
  func showRequestList() {
    detailTask?.cancel()
    requestsTable.deselectAll(nil)
    selected = nil; detailReady = false
    requestList.isHidden = false
    requestOverview.isHidden = true
    rightContent.isHidden = true
    updateListState()
  }
  private func showRequestOverview(_ request: HostedRequest) {
    status.stringValue = ""
    requestTitle.stringValue = "#\(request.number) \(request.title)"
    requestTitle.toolTip = request.title
    requestBranches.stringValue = "\(request.source) → \(request.target)"
    requestAuthor.stringValue = "\(request.author) · \(request.draft ? "Draft" : request.state)"
    requestList.isHidden = true
    requestOverview.isHidden = false
    rightContent.isHidden = false
  }
  func useClient(_ client: HostingClient, repository: GitRepository?) {
    _ = view
    task?.cancel(); detailTask?.cancel(); selected = nil; detailReady = false; showRequestList()
    self.repo = repository; self.context = client.repository; self.client = client
    openedRequest = nil; selectOpenedButton.isEnabled = false; listError = nil
    repositoryButton.title = client.repository.project
    updateFilterControls()
    if remotePicker.numberOfItems == 0 { remotePicker.addItem(withTitle: client.repository.remote) }
    reload()
  }
  private func updateActionState() {
    let ready = selected != nil && detailReady && !writing
    for button in requestButtons.values { button.isEnabled = ready }
    if let selected {
      requestButtons["Merge…"]?.isEnabled = ready && !selected.draft && ["open", "opened"].contains(selected.state)
      requestButtons["Close / Reopen…"]?.isEnabled = ready && selected.state != "merged"
    }
  }
  func configure(repository: GitRepository?, force: Bool = false) {
    _ = view
    guard force || repo?.workingDirectory != repository?.workingDirectory else { return }
    repo = repository; task?.cancel(); detailTask?.cancel(); selected = nil; detailReady = false; showRequestList()
    remotes = []; requests = []; displayed = []; files = []; requestsTable.reloadData(); filesTable.reloadData()
    remotePicker.removeAllItems(); context = nil; client = nil; openedRequest = nil; selectOpenedButton.isEnabled = false
    repositoryButton.title = "Code Reviews"; listLoading = false; listError = nil
    overview.string = "Select a request to view its description, changed files, discussion, reviews and CI checks."
    guard let repository else { status.stringValue = "Open a repository to connect a hosting account."; updateListState(); return }
    task = Task { @MainActor [weak self] in
      do {
        let values = try await Task.detached { () -> [(String, String)] in
          let inspection = GitRepository(directory: repository.workingDirectory)
          let names = try inspection.run(["remote"]).split(separator: "\n").map(String.init)
          return try names.map { ($0, try inspection.run(["remote", "get-url", $0]).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }.value
        guard let self, !Task.isCancelled else { return }
        self.remotes = values; self.remotePicker.addItems(withTitles: values.map(\.0))
        if values.contains(where: { $0.0 == "origin" }) { self.remotePicker.selectItem(withTitle: "origin") }
        if let valid = values.firstIndex(where: { (try? HostingRepository(remoteURL: $0.1, remote: $0.0)) != nil }),
          (try? HostingRepository(remoteURL: values[self.remotePicker.indexOfSelectedItem].1, remote: values[self.remotePicker.indexOfSelectedItem].0)) == nil {
          self.remotePicker.selectItem(at: valid)
        }
        self.remoteChanged()
      } catch { if !Task.isCancelled { self?.status.stringValue = error.localizedDescription; self?.updateListState() } }
    }
  }
  @objc private func remoteChanged() {
    guard !writing else { return }
    task?.cancel(); detailTask?.cancel(); selected = nil; detailReady = false
    context = nil; client = nil; openedRequest = nil; selectOpenedButton.isEnabled = false; showRequestList()
    requests = []; displayed = []; files = []; requestsTable.reloadData(); filesTable.reloadData()
    overview.string = "Select a request to view its details."; discussion.string = ""; checks.string = ""; patch.string = ""
    let index = remotePicker.indexOfSelectedItem
    guard remotes.indices.contains(index) else { status.stringValue = "No remote configured. Add one using Git → Manage Remotes."; updateListState(); return }
    do {
      let remote = remotes[index]
      let detected = try HostingRepository(remoteURL: remote.url, remote: remote.name)
      let profiles = UserDefaults.standard.dictionary(forKey: "hosting.servers") as? [String: [String: String]] ?? [:]
      let profile = profiles[detected.server.host ?? ""]
      let provider = profile?["provider"].flatMap(HostingProvider.init(rawValue:)) ?? detected.provider
      let server = profile?["server"].flatMap(URL.init(string:)) ?? detected.server
      context = try HostingRepository(remoteURL: remote.url, remote: remote.name, provider: provider, server: server)
      repositoryButton.title = context!.project
      useClient(HostingClient(repository: context!, token: try HostingCredentials.token(for: context!.credentialKey)), repository: repo)
    } catch { status.stringValue = error.localizedDescription; updateListState() }
  }
  func reload(more: Bool = false) {
    guard !writing, let client else { updateListState(); return }
    if more && (!hasMore || listLoading) { return }
    searchWork?.cancel()
    task?.cancel()
    let next = more ? page + 1 : 1
    let filter = requestFilter
    listLoading = true; listError = nil
    if !more { requests = []; displayed = []; requestsTable.reloadData() }
    updateListState()
    task = Task { @MainActor [weak self] in
      do {
        let requests = try await client.list(filter: filter, page: next)
        guard let self, !Task.isCancelled else { return }
        self.requests = more ? self.requests + requests : requests
        self.displayed = self.requests
        self.page = next; self.hasMore = requests.count == 50; self.listLoading = false
        self.requestsTable.reloadData(); self.updateListState()
        if !more, !self.requestOverview.isHidden, let selected = self.selected {
          self.loadDetails(selected, client: client)
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.listLoading = false; self.listError = error.localizedDescription
        self.updateListState()
      }
    }
  }
  func controlTextDidBeginEditing(_ obj: Notification) { search.needsDisplay = true }
  func controlTextDidEndEditing(_ obj: Notification) { search.needsDisplay = true }
  func controlTextDidChange(_ obj: Notification) {
    requestFilter.query = search.stringValue
    searchWork?.cancel()
    // Cancel immediately so a previous search cannot repaint while typing.
    task?.cancel(); listLoading = false
    let work = DispatchWorkItem { [weak self] in self?.reload() }
    searchWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }
  func clearFilters() {
    requestFilter = HostedRequestFilter(); requestFilter.state = "all"
    search.stringValue = ""; updateFilterControls(); reload()
  }
  func setFilter(_ key: String, value: String) {
    switch key {
    case "State": requestFilter.state = value
    case "Author": requestFilter.author = value
    case "Label": requestFilter.label = value
    case "Assignee": requestFilter.assignee = value
    case "Review": requestFilter.review = value
    case "Sort": requestFilter.sort = value
    default: return
    }
    showRequestList(); updateFilterControls(); reload()
  }
  private func updateListState() {
    listEmpty.isHidden = !displayed.isEmpty
    listEmptyAction.isHidden = listLoading
    if listLoading { listEmptyMessage.stringValue = "Loading…" }
    else if let listError {
      listEmptyMessage.stringValue = "Could not load requests.\n" + listError
      listEmptyAction.title = "Retry"
    } else if client == nil {
      listEmptyMessage.stringValue = status.stringValue
      listEmptyAction.title = "Connect Account…"
    } else {
      let noun = context?.provider == .gitlab ? "merge requests" : "pull requests"
      listEmptyMessage.stringValue = requestFilter.isEmpty ? "No \(noun) in \(context?.project ?? "this repository")" : "No \(noun) matching filters"
      listEmptyAction.title = "Clear filters"
      listEmptyAction.isHidden = requestFilter.isEmpty
    }
    listEmptyAction.attributedTitle = NSAttributedString(string: listEmptyAction.title,
      attributes: [.font: Theme.font, .foregroundColor: Theme.blue, .underlineStyle: NSUnderlineStyle.single.rawValue])
  }
  @objc func openSelectedRequest() {
    let index = requestsTable.selectedRow
    guard displayed.indices.contains(index), let client else { return }
    selected = displayed[index]; openedRequest = selected; selectOpenedButton.isEnabled = true; detailReady = false
    showRequestOverview(selected!); selectSection(0); loadDetails(selected!, client: client)
  }
  func numberOfRows(in tableView: NSTableView) -> Int { tableView === requestsTable ? displayed.count : files.count }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRow() }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
    let cell = NSTableCellView()
    if tableView === requestsTable {
      guard displayed.indices.contains(index) else { return nil }
      let request = displayed[index]
      let title = label(request.title); title.lineBreakMode = .byTruncatingTail; title.usesSingleLineMode = true
      let created = request.createdAt.map { LogDateFormatter().string($0) } ?? ""
      let metadata = label("#\(request.number) · " + (created.isEmpty ? "" : "created \(created), ") + "by \(request.author)", color: Theme.muted, size: 12)
      let stack = NSStackView(views: [title, metadata]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
      let comments = label((request.draft ? "DRAFT   " : "") + "\(request.commentCount)", color: Theme.muted, size: 12)
      let commentIcon = NSImageView(image: NSImage(systemSymbolName: "bubble.right", accessibilityDescription: "Comments") ?? NSImage())
      commentIcon.contentTintColor = Theme.muted
      pin(row([stack, NSView(), commentIcon, comments], spacing: 6), to: cell, inset: 10); cell.toolTip = request.title
    } else {
      guard files.indices.contains(index) else { return nil }
      let file = files[index], icon = FileTypeImageView(path: files[index].path)
      icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
      icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
      let name = label(file.path, color: file.status == "added" ? Theme.green : file.status == "removed" ? Theme.red : Theme.blue)
      name.lineBreakMode = .byTruncatingMiddle
      pin(row([icon, name]), to: cell, inset: 7); cell.toolTip = file.path
    }
    return cell
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    if notification.object as? NSTableView === filesTable {
      let index = filesTable.selectedRow
      patch.string = files.indices.contains(index) ? files[index].patch : ""
      let text = NSMutableAttributedString(string: patch.string, attributes: [.font: DiffFont.regular(), .foregroundColor: Theme.text])
      var offset = 0
      for line in patch.string.components(separatedBy: "\n") {
        let length = (line as NSString).length
        if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@") {
          text.addAttribute(.foregroundColor, value: line.hasPrefix("+") ? Theme.green : line.hasPrefix("-") ? Theme.red : Theme.blue, range: NSRange(location: offset, length: length))
        }
        offset += length + 1
      }
      patch.textStorage?.setAttributedString(text)
      selectSection(1)
      return
    }
    // Selection leaves the list visible. Enter or double-click opens a request.
  }
  private func loadDetails(_ request: HostedRequest, client: HostingClient) {
    detailReady = false
    detailTask?.cancel(); files = []; filesTable.reloadData(); patch.string = ""
    threads = []; threadPicker.removeAllItems()
    overview.string = "Loading #\(request.number)…"; discussion.string = "Loading discussion…"; checks.string = "Loading checks and reviews…"
    detailTask = Task { @MainActor [weak self] in
      do {
        let detail = try await client.details(request.number)
        guard let self, !Task.isCancelled else { return }
        self.selected = detail; self.detailReady = true; self.showRequestOverview(detail)
        self.overview.string = "#\(detail.number) \(detail.title)\n\n\(detail.source) → \(detail.target)\n\(detail.author) · \(detail.state)\(detail.draft ? " · Draft" : "")\nMerge status: \(detail.mergeStatus)\n\n\(detail.body)"
        do {
          let files = try await client.files(detail.number)
          guard !Task.isCancelled else { return }
          self.files = files; self.filesTable.reloadData()
        } catch { if !Task.isCancelled { self.patch.string = error.localizedDescription } }
        do {
          let comments = try await client.comments(detail.number)
          guard !Task.isCancelled else { return }
          self.discussion.string = comments.isEmpty ? "No comments yet." : comments.map { "\($0.author)\n\($0.body)" }.joined(separator: "\n\n────────\n\n")
        } catch { if !Task.isCancelled { self.discussion.string = error.localizedDescription } }
        do {
          let threads = try await client.threads(detail.number)
          guard !Task.isCancelled else { return }
          self.threads = threads
          self.threadPicker.addItems(withTitles: threads.map { ($0.resolved ? "✓ " : "○ ") + $0.summary })
          if !threads.isEmpty { self.discussion.string += "\n\nLine Discussions\n\n" + threads.map { "\($0.summary) · \($0.resolved ? "Resolved" : "Unresolved")\n\($0.body)" }.joined(separator: "\n\n────────\n\n") }
        } catch { if !Task.isCancelled { self.discussion.string += "\n\nLine discussions: " + error.localizedDescription } }
        var sections: [String] = []
        do { sections.append("CI checks\n" + (try await client.status(detail))) }
        catch { sections.append("CI checks\n" + error.localizedDescription) }
        do { sections.append("Reviews\n" + (try await client.reviews(detail.number))) }
        catch { sections.append("Reviews\n" + error.localizedDescription) }
        guard !Task.isCancelled else { return }
        self.checks.string = sections.joined(separator: "\n\n")
      } catch { if !Task.isCancelled { self?.overview.string = error.localizedDescription } }
    }
  }
  private func connect() {
    guard !writing else { return }
    let existingContext = context
    let defaultServer = existingContext?.server.absoluteString ?? "https://github.com"
    let alert = NSAlert(); alert.messageText = "Connect Hosting Account"
    alert.informativeText = "Use a personal access token with repository/PR write permissions (GitHub) or api scope (GitLab). The token is stored in macOS Keychain."
    let provider = NSPopUpButton(); provider.addItems(withTitles: ["GitHub", "GitLab"]); provider.selectItem(at: existingContext?.provider == .gitlab ? 1 : 0)
    let server = NSTextField(string: defaultServer), token = NSSecureTextField(string: "")
    token.placeholderString = "Personal access token"
    let form = NSStackView(views: [provider, label("Server URL"), server, label("Access Token"), token])
    form.orientation = .vertical; form.alignment = .leading; form.spacing = 8
    form.frame = NSRect(x: 0, y: 0, width: 460, height: 155)
    for field in [server, token] { field.widthAnchor.constraint(equalToConstant: 460).isActive = true }
    alert.accessoryView = form; alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      guard let url = URL(string: server.stringValue), !token.stringValue.isEmpty else { throw GitFailure("Enter the server URL and token.") }
      let remote = remotes.indices.contains(remotePicker.indexOfSelectedItem) ? remotes[remotePicker.indexOfSelectedItem]
        : (name: "origin", url: url.appendingPathComponent("gitdesk/account.git").absoluteString)
      let configuration = try HostingRepository(remoteURL: remote.url, remote: remote.name, provider: provider.indexOfSelectedItem == 0 ? .github : .gitlab, server: url)
      let secret = token.stringValue; token.stringValue = ""
      let candidate = HostingClient(repository: configuration, token: secret)
      task?.cancel(); status.stringValue = "Validating account…"; updateListState()
      task = Task { @MainActor [weak self] in
        do {
          let user = try await candidate.object("/user")
          guard let self, !Task.isCancelled else { return }
          try HostingCredentials.save(secret, for: configuration.credentialKey)
          var profiles = UserDefaults.standard.dictionary(forKey: "hosting.servers") as? [String: [String: String]] ?? [:]
          profiles[(try? HostingRepository(remoteURL: remote.url, remote: remote.name).server.host) ?? configuration.server.host!] = ["provider": configuration.provider.rawValue, "server": configuration.server.absoluteString]
          UserDefaults.standard.set(profiles, forKey: "hosting.servers")
          self.status.stringValue = "Connected as \(user["login"] ?? user["username"] ?? "account")"
          if !self.remotes.isEmpty {
            self.selected = nil; self.detailReady = false; self.requests = []; self.displayed = []
            self.requestsTable.reloadData()
            self.context = configuration; self.client = candidate; self.repositoryButton.title = configuration.project; self.reload()
          } else { self.status.stringValue += ". Open or clone a repository to view its requests." }
        } catch { if !Task.isCancelled { self?.status.stringValue = error.localizedDescription; self?.updateListState() } }
      }
    } catch { status.stringValue = error.localizedDescription; updateListState() }
  }
  private func accountMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Connect / Replace Token…") { [weak self] in self?.connect() })
    menu.addItem(menuItem("Share Code Snippet…", enabled: context != nil) { [weak self] in self?.createSnippet() })
    menu.addItem(menuItem("Disconnect Account", enabled: context != nil) { [weak self] in
      guard let self, let context = self.context else { return }
      do { try HostingCredentials.remove(context.credentialKey); self.client = HostingClient(repository: context, token: ""); self.reload() }
      catch { self.status.stringValue = error.localizedDescription }
    })
    menu.popUp(positioning: nil, at: NSPoint(x: navigationSplit.subviews[0].frame.maxX - 80, y: view.bounds.maxY - 36), in: view)
  }
  private func prompt(_ title: String, fields: [(String, String)], multiline: Bool = false, extra: NSView? = nil) -> [String]? {
    let alert = NSAlert(); alert.messageText = title
    let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
    var controls: [NSTextField] = []
    for (caption, value) in fields {
      let field = NSTextField(string: value)
      if caption == "Location" { field.isEditable = false }
      field.widthAnchor.constraint(equalToConstant: 480).isActive = true
      if multiline && caption == "Body" { field.usesSingleLineMode = false; field.heightAnchor.constraint(equalToConstant: 120).isActive = true }
      stack.addArrangedSubview(label(caption)); stack.addArrangedSubview(field); controls.append(field)
    }
    if let extra { stack.addArrangedSubview(extra) }
    stack.frame = NSRect(x: 0, y: 0, width: 480, height: CGFloat(fields.count * 50 + (multiline ? 100 : 0) + (extra == nil ? 0 : 30)))
    alert.accessoryView = stack; alert.addButton(withTitle: title); alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return controls.map(\.stringValue)
  }
  private func write(_ title: String, operation: @escaping (HostingClient) async throws -> Void) {
    guard let client, !writing else { return }
    writing = true; remotePicker.isEnabled = false; status.stringValue = title + "…"
    Task { @MainActor [weak self] in
      do { try await operation(client); self?.writing = false; self?.remotePicker.isEnabled = true; self?.status.stringValue = ""; self?.reload() }
      catch { self?.writing = false; self?.remotePicker.isEnabled = true; self?.status.stringValue = error.localizedDescription; self?.updateListState() }
    }
  }
  private func createRequest() {
    guard !writing else { return }
    guard context != nil, let repo else { return }
    let source = (try? repo.run(["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    let draft = NSButton(checkboxWithTitle: "Create as draft", target: nil, action: nil)
    guard let values = prompt("Create Request", fields: [("Title", ""), ("Source branch (push first; GitHub forks: owner:branch)", source), ("Target branch", "main"), ("Body", "")], multiline: true, extra: draft),
      !values[0].isEmpty, !values[1].isEmpty, !values[2].isEmpty else { return }
    write("Creating request") { client in _ = try await client.create(title: values[0], body: values[3], source: values[1], target: values[2], draft: draft.state == .on) }
  }
  private func sendComment() {
    guard let request = selected, let values = prompt("Send Comment", fields: [("Body", "")], multiline: true), !values[0].isEmpty else { return }
    write("Sending comment") { try await $0.comment(request.number, body: values[0]) }
  }
  private func reviewMenu() {
    guard detailReady, let request = selected else { return }
    let menu = NSMenu()
    menu.addItem(menuItem("Edit Title / Description…") { [weak self] in
      guard let self, let values = self.prompt("Save Changes", fields: [("Title", request.title), ("Body", request.body)], multiline: true), !values[0].isEmpty else { return }
      self.write("Updating request") { try await $0.edit(request.number, title: values[0], body: values[1]) }
    })
    menu.addItem(menuItem(request.draft ? "Mark Ready for Review" : "Convert to Draft") { [weak self] in
      self?.write("Updating draft state") { try await $0.setDraft(request, draft: !request.draft) }
    })
    menu.addItem(menuItem("Request Reviewers…") { [weak self] in
      guard let self, let values = self.prompt("Request Reviewers", fields: [("Usernames (comma separated)", "")]) else { return }
      let usernames = values[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      guard !usernames.isEmpty else { return }
      self.write("Requesting reviewers") { try await $0.requestReviewers(request.number, usernames: usernames) }
    })
    menu.addItem(.separator())
    for (title, event) in [("Approve…", "APPROVE"), (context?.provider == .github ? "Request Changes…" : "Unapprove…", context?.provider == .github ? "REQUEST_CHANGES" : "UNAPPROVE"), ("Comment Review…", "COMMENT")] {
      menu.addItem(menuItem(title) { [weak self] in
        guard let self, let values = self.prompt(title, fields: [("Body", "")], multiline: true) else { return }
        if event == "REQUEST_CHANGES" || event == "COMMENT", values[0].isEmpty { return }
        self.write("Submitting review") { try await $0.review(request, action: event, body: values[0]) }
      })
    }
    if let anchor = requestButtons["Review…"] { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor) }
  }
  private func mergeMenu() {
    guard detailReady, let request = selected, request.state == "open" || request.state == "opened", !request.draft else { return }
    let menu = NSMenu()
    for method in context?.provider == .github ? ["merge", "squash", "rebase"] : ["merge", "squash"] {
      menu.addItem(menuItem(method.capitalized + "…") { [weak self] in
        guard let self else { return }
        let alert = NSAlert(); alert.messageText = "\(method.capitalized) #\(request.number)?"
        alert.informativeText = "Merge \(request.source) into \(request.target) on \(self.context?.server.host ?? "server"). Server branch protections still apply."
        alert.addButton(withTitle: "Merge"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        self.write("Merging request") { try await $0.merge(request, method: method) }
      })
    }
    if let anchor = requestButtons["Merge…"] { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor) }
  }
  private func changeState() {
    guard let request = selected, request.state != "merged" else { return }
    let open = request.state == "closed"
    let alert = NSAlert(); alert.messageText = "\(open ? "Reopen" : "Close") #\(request.number)?"
    alert.addButton(withTitle: open ? "Reopen" : "Close Request"); alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    write("Updating request") { try await $0.setState(request.number, open: open) }
  }
  private func openBrowser() { if let request = selected { NSWorkspace.shared.open(request.url) } }
  private func checkOut() { if detailReady, let context, let selected { checkout?(context, selected) } }
  private func openFullDiff() { if detailReady, let context, let selected { showDiff?(context, selected, nil) } }
  @objc private func openFileDiff() {
    if detailReady, let context, let selected, files.indices.contains(filesTable.selectedRow) { showDiff?(context, selected, files[filesTable.selectedRow].path) }
  }
  private func replyToThread() {
    let index = threadPicker.indexOfSelectedItem
    guard let request = selected, threads.indices.contains(index), let values = prompt("Reply", fields: [("Body", "")], multiline: true), !values[0].isEmpty else { return }
    let thread = threads[index]
    write("Sending reply") { try await $0.reply(request.number, thread: thread, body: values[0]) }
  }
  private func resolveThread() {
    let index = threadPicker.indexOfSelectedItem
    guard let request = selected, threads.indices.contains(index), threads[index].canResolve else { return }
    let thread = threads[index]
    write("Updating discussion") { try await $0.resolve(request.number, thread: thread) }
  }
  private func createSnippet() {
    guard let context else { return }
    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
    panel.message = "Select text files to share as a \(context.provider == .github ? "gist" : "project snippet")."
    guard panel.runModal() == .OK else { return }
    do {
      var files: [String: String] = [:]
      for url in panel.urls {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw GitFailure("Select text files smaller than 2 MB.") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw GitFailure("Only UTF-8 text files can be shared.") }
        guard files[url.lastPathComponent] == nil else { throw GitFailure("Selected files must have different names.") }
        files[url.lastPathComponent] = text
      }
      let publicSnippet = NSButton(checkboxWithTitle: "Make public (visible to everyone)", target: nil, action: nil)
      guard let values = prompt("Share Code Snippet", fields: [("Title / Description", "")], extra: publicSnippet) else { return }
      write("Sharing code snippet") { client in
        let result = try await client.createSnippet(title: values[0], files: files, isPublic: publicSnippet.state == .on)
        await MainActor.run { _ = NSWorkspace.shared.open(result) }
      }
    } catch { status.stringValue = error.localizedDescription; updateListState() }
  }
  func commentOnLine(context: HostingRepository, request: HostedRequest, path: String, oldPath: String, line: Int, left: Bool) {
    guard self.context == context else {
      status.stringValue = "Open this request's repository in Reviews before commenting."; return
    }
    guard let values = prompt("Send Line Comment", fields: [("Location", "#\(request.number) · \(path):\(line) (\(left ? "original" : "updated"))"), ("Body", "")], multiline: true), !values[1].isEmpty else { return }
    write("Sending line comment") { try await $0.lineComment(request, path: path, oldPath: oldPath, line: line, left: left, body: values[1]) }
  }
  private func requestMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(menuItem("Check Out", enabled: selected != nil && detailReady) { [weak self] in self?.checkOut() })
    menu.addItem(menuItem("Show Diff", enabled: selected != nil && detailReady) { [weak self] in self?.openFullDiff() })
    menu.addItem(menuItem("Open on Server", enabled: selected != nil && detailReady) { [weak self] in self?.openBrowser() })
    return menu
  }
}

final class HostingRequestTable: MenuTable {
  var openRequest: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 { openRequest?(); return }
    super.keyDown(with: event)
  }
}

private final class ReviewFilterControl: NSStackView {
  let button: ActionButton
  let clearButton: ActionButton
  init(name: String, choose: @escaping () -> Void, clear: @escaping () -> Void) {
    button = ActionButton(name, symbol: "chevron.down", size: 26, action: choose)
    button.imagePosition = .imageTrailing
    button.image = button.image?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
    button.setAccessibilityLabel(name)
    clearButton = ActionButton(symbol: "xmark", tooltip: "Clear " + name, size: 16, action: clear)
    clearButton.image = clearButton.image?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
    super.init(frame: .zero)
    orientation = .horizontal; alignment = .centerY; spacing = 2
    addArrangedSubview(button); addArrangedSubview(clearButton)
    clearButton.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  func update(name: String, value: String, caption: String) {
    button.title = value.isEmpty ? name : caption
    button.contentTintColor = value.isEmpty ? Theme.muted : Theme.text
    button.image = value.isEmpty ? NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular)) : nil
    clearButton.isHidden = value.isEmpty
    button.invalidateIntrinsicContentSize()
  }
}

private extension HostingWorkspace {
  func buildFilterBar() -> NSView {
    let quick = ToolWindowButton(icon: "filter", tooltip: "Quick Filters", size: 24, iconSize: 16) { [weak self] in self?.quickFilters() }
    quickFilterButton = quick
    let controls = ["State", "Author", "Label", "Assignee", "Review", "Sort"].map { name -> ReviewFilterControl in
      let control = ReviewFilterControl(name: name, choose: { [weak self] in self?.chooseFilter(name) },
        clear: { [weak self] in self?.setFilter(name, value: name == "State" ? "all" : "") })
      filterControls[name] = control
      return control
    }
    let contents = row(controls, spacing: 12)
    contents.translatesAutoresizingMaskIntoConstraints = false
    let scroll = NSScrollView(); scroll.drawsBackground = false
    scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
    scroll.documentView = contents
    NSLayoutConstraint.activate([
      contents.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      contents.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      contents.heightAnchor.constraint(equalToConstant: 28),
    ])
    let bar = row([quick, scroll], spacing: 6)
    updateFilterControls()
    return bar
  }
  func updateFilterControls() {
    quickFilterButton?.showsActivityBadge = !requestFilter.isEmpty
    for (key, value) in [("State", requestFilter.state == "all" ? "" : requestFilter.state), ("Author", requestFilter.author),
      ("Label", requestFilter.label), ("Assignee", requestFilter.assignee), ("Review", requestFilter.review), ("Sort", requestFilter.sort)] {
      let caption = filterChoices(key).first { $0.1 == value }?.0 ?? value
      filterControls[key]?.update(name: key == "Review" && context?.provider == .gitlab ? "Reviewer" : key, value: value, caption: caption)
    }
  }
  func filterChoices(_ name: String) -> [(String, String)] {
    switch name {
    case "State": return [("Open", "open"), ("Closed", "closed"), ("Merged", "merged")]
    case "Sort":
      var choices = [("Newest", "created-desc"), ("Oldest", "created-asc")]
      if context?.provider != .gitlab { choices += [("Most commented", "comments-desc"), ("Least commented", "comments-asc")] }
      return choices + [("Recently updated", "updated-desc"), ("Least recently updated", "updated-asc")]
    case "Review" where context?.provider != .gitlab:
      return [("No reviews", "review:none"), ("Review required", "review:required"), ("Approved review", "review:approved"),
        ("Changes requested", "review:changes_requested"), ("Reviewed by you", "reviewed-by:@me"),
        ("Not reviewed by you", "-reviewed-by:@me"), ("Awaiting review from you", "review-requested:@me")]
    case "Author": return Array(Set(requests.map(\.author))).sorted().map { ($0, $0) }
    default: return []
    }
  }
  func chooseFilter(_ name: String) {
    guard let anchor = filterControls[name]?.button else { return }
    let menu = NSMenu()
    for (caption, value) in filterChoices(name) {
      menu.addItem(menuItem(caption) { [weak self] in self?.setFilter(name, value: value) })
    }
    if ["Author", "Label", "Assignee"].contains(name) || name == "Review" && context?.provider == .gitlab {
      menu.addItem(menuItem("Choose \(name == "Review" ? "Reviewer" : name)…") { [weak self] in
        guard let self, let values = self.prompt("Apply \(name)", fields: [(name == "Label" ? "Label" : "Username", "")]) else { return }
        self.setFilter(name, value: values[0].trimmingCharacters(in: .whitespacesAndNewlines))
      })
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("Clear \(name)") { [weak self] in self?.setFilter(name, value: name == "State" ? "all" : "") })
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
  }
  func quickFilters() {
    let menu = NSMenu()
    for (caption, key) in [("Open", "State"), ("Your pull requests", "Author"), ("Assigned to you", "Assignee"), ("Review requests", "Review")] {
      menu.addItem(menuItem(context?.provider == .gitlab ? caption.replacingOccurrences(of: "pull", with: "merge") : caption) { [weak self] in
        guard let self else { return }
        self.requestFilter = HostedRequestFilter()
        self.search.stringValue = ""
        self.setFilter(key, value: key == "State" ? "open" : key == "Review" && self.context?.provider != .gitlab ? "review-requested:@me" : "@me")
      })
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("Clear filters") { [weak self] in self?.clearFilters() })
    menu.popUp(positioning: nil, at: NSPoint(x: 12, y: requestList.bounds.height - 80), in: requestList)
  }
  func repositoryMenu() {
    let menu = NSMenu()
    for (index, remote) in remotes.enumerated() {
      let title = (try? HostingRepository(remoteURL: remote.url, remote: remote.name).project) ?? remote.name
      menu.addItem(menuItem(title + " (" + remote.name + ")", enabled: !writing) { [weak self] in
        self?.remotePicker.selectItem(at: index); self?.remoteChanged()
      })
    }
    if remotes.isEmpty { menu.addItem(menuItem("No repositories with a hosting remote", enabled: false) {}) }
    menu.addItem(.separator())
    menu.addItem(menuItem("Connect Account…") { [weak self] in self?.connect() })
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: repositoryButton.bounds.maxY), in: repositoryButton)
  }
  func listOptions() {
    let menu = NSMenu()
    menu.addItem(menuItem("Refresh List") { [weak self] in self?.reload() })
    menu.addItem(menuItem("Clear filters") { [weak self] in self?.clearFilters() })
    menu.addItem(menuItem("Account…") { [weak self] in self?.accountMenu() })
    menu.popUp(positioning: nil, at: NSPoint(x: navigationSplit.subviews[0].bounds.width - 32, y: view.bounds.height - 40), in: view)
  }
  func revealOpenedRequest() {
    guard let openedRequest, let client else { return }
    selected = openedRequest
    showRequestOverview(openedRequest); loadDetails(openedRequest, client: client)
  }
}
