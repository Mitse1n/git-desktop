import AppKit
import GitDeskCore

final class HostingWorkspace: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  private let remotePicker = NSPopUpButton()
  private let statePicker = NSPopUpButton()
  private let search = NSSearchField()
  let requestsTable = MenuTable()
  let filesTable = MenuTable()
  private let overview = NSTextView(), patch = NSTextView(), discussion = NSTextView(), checks = NSTextView()
  private let status = label("Open a repository with a GitHub or GitLab remote.", color: Theme.muted, size: 12)
  private let heading = label("Code Reviews", bold: true)
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
  var checkout: ((HostingRepository, HostedRequest) -> Void)?
  var showDiff: ((HostingRepository, HostedRequest, String?) -> Void)?
  override func loadView() {
    view = Surface()
    remotePicker.target = self; remotePicker.action = #selector(remoteChanged)
    statePicker.addItems(withTitles: ["Open", "Closed", "All"])
    statePicker.target = self; statePicker.action = #selector(reloadFromFilter)
    search.placeholderString = "Title, author or number"; search.delegate = self
    search.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    let toolbar = row([heading, NSView(),
      ActionButton(symbol: "arrow.clockwise", tooltip: "Refresh Requests") { [weak self] in self?.reload() },
      ActionButton(symbol: "person.crop.circle", tooltip: "Account…") { [weak self] in self?.accountMenu() },
      ActionButton(symbol: "plus", tooltip: "Create Request…") { [weak self] in self?.createRequest() }], spacing: 4)
    let filters = row([remotePicker, statePicker, NSView()], spacing: 6)
    let searchRow = row([search])
    for table in [requestsTable, filesTable] {
      configureTable(table); table.delegate = self; table.dataSource = self; table.rowHeight = 48
      table.addTableColumn(NSTableColumn(identifier: .init("content")))
    }
    requestsTable.setAccessibilityLabel("Pull requests and merge requests")
    filesTable.setAccessibilityLabel("Changed files")
    filesTable.target = self; filesTable.doubleAction = #selector(openFileDiff)
    requestsTable.menuProvider = { [weak self] in self?.requestMenu() ?? NSMenu() }
    let list = makePanel(row([label("Requests", bold: true), NSView(), ActionButton("Load More") { [weak self] in self?.reload(more: true) }]), body: scrollView(requestsTable), height: 32)
    pin(makePanel(filters, body: makePanel(searchRow, body: list, height: 34), height: 32), to: requestList)
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
      row([checkout, diff, NSView()]), row([review, merge, close, NSView()]), row([comment, NSView()])])
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
    let left = makePanel(toolbar, body: makePanel(row([status]), body: navigation, height: 44), height: 36)
    left.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
    left.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
    tabs.tabViewType = .noTabsNoBorder
    sectionButtons = ["Overview", "Files", "Timeline", "Checks & Reviews"].enumerated().map { index, title in
      let button = ActionButton(title) { [weak self] in self?.selectSection(index) }
      button.isTab = true
      return button
    }
    let sections = row(sectionButtons + [NSView()], spacing: 14)
    let right = makePanel(sections, body: tabs, height: 36)
    navigationSplit.isVertical = true; navigationSplit.dividerStyle = .thin
    navigationSplit.autosaveName = "ReviewToolWindowSplit"
    navigationSplit.addArrangedSubview(left); navigationSplit.addArrangedSubview(right)
    pin(navigationSplit, to: view)
    updateActionState()
    overview.string = "Select a request to view its description, changed files, discussion, reviews and CI checks."
    selectSection(0)
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
      navigationSplit.setPosition(380, ofDividerAt: 0)
    }
  }
  func showRequestList() {
    detailTask?.cancel()
    requestsTable.deselectAll(nil)
    selected = nil; detailReady = false
    requestList.isHidden = false
    requestOverview.isHidden = true
  }
  private func showRequestOverview(_ request: HostedRequest) {
    requestTitle.stringValue = "#\(request.number) \(request.title)"
    requestTitle.toolTip = request.title
    requestBranches.stringValue = "\(request.source) → \(request.target)"
    requestAuthor.stringValue = "\(request.author) · \(request.draft ? "Draft" : request.state)"
    requestList.isHidden = true
    requestOverview.isHidden = false
  }
  func useClient(_ client: HostingClient, repository: GitRepository?) {
    _ = view
    task?.cancel(); detailTask?.cancel(); selected = nil; detailReady = false; showRequestList()
    self.repo = repository; self.context = client.repository; self.client = client
    heading.stringValue = client.repository.provider.requestTitle
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
    remotePicker.removeAllItems(); context = nil; client = nil
    overview.string = "Select a request to view its description, changed files, discussion, reviews and CI checks."
    guard let repository else { status.stringValue = "Open a repository to connect a hosting account."; return }
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
        self.remoteChanged()
      } catch { if !Task.isCancelled { self?.status.stringValue = error.localizedDescription } }
    }
  }
  @objc private func remoteChanged() {
    guard !writing else { return }
    task?.cancel(); detailTask?.cancel(); selected = nil; detailReady = false
    context = nil; client = nil; showRequestList()
    requests = []; displayed = []; files = []; requestsTable.reloadData(); filesTable.reloadData()
    overview.string = "Select a request to view its details."; discussion.string = ""; checks.string = ""; patch.string = ""
    let index = remotePicker.indexOfSelectedItem
    guard remotes.indices.contains(index) else { status.stringValue = "No remote configured. Add one using Git → Manage Remotes."; return }
    do {
      let remote = remotes[index]
      let detected = try HostingRepository(remoteURL: remote.url, remote: remote.name)
      let profiles = UserDefaults.standard.dictionary(forKey: "hosting.servers") as? [String: [String: String]] ?? [:]
      let profile = profiles[detected.server.host ?? ""]
      let provider = profile?["provider"].flatMap(HostingProvider.init(rawValue:)) ?? detected.provider
      let server = profile?["server"].flatMap(URL.init(string:)) ?? detected.server
      context = try HostingRepository(remoteURL: remote.url, remote: remote.name, provider: provider, server: server)
      heading.stringValue = provider.requestTitle
      useClient(HostingClient(repository: context!, token: try HostingCredentials.token(for: context!.credentialKey)), repository: repo)
    } catch { status.stringValue = error.localizedDescription }
  }
  @objc private func reloadFromFilter() { reload() }
  func reload(more: Bool = false) {
    guard !writing else { return }
    guard let client else { if !more { configure(repository: repo, force: true) }; return }
    if more && !hasMore { status.stringValue = "All loaded requests are shown."; return }
    task?.cancel(); let next = more ? page + 1 : 1
    let state = ["open", "closed", "all"][max(0, statePicker.indexOfSelectedItem)]
    status.stringValue = "Loading \(client.repository.provider.requestTitle.lowercased())…"
    task = Task { @MainActor [weak self] in
      do {
        let requests = try await client.list(state: state, page: next)
        guard let self, !Task.isCancelled else { return }
        let previous = self.selected?.number
        self.requests = more ? self.requests + requests : requests
        self.page = next; self.hasMore = requests.count == 50; self.applySearch()
        self.status.stringValue = "\(client.repository.project) · \(self.requests.count) requests" + (self.hasMore ? " · Load More available" : "")
        if let row = self.displayed.firstIndex(where: { $0.number == previous }) {
          self.requestsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
      } catch { if !Task.isCancelled { self?.status.stringValue = error.localizedDescription + " Connect Account for private repositories." } }
    }
  }
  func controlTextDidChange(_ obj: Notification) { applySearch() }
  private func applySearch() {
    let query = search.stringValue
    displayed = requests.filter { query.isEmpty || "\($0.number) \($0.title) \($0.author)".localizedCaseInsensitiveContains(query) }
    requestsTable.reloadData()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { tableView === requestsTable ? displayed.count : files.count }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRow() }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
    let cell = NSTableCellView()
    if tableView === requestsTable {
      guard displayed.indices.contains(index) else { return nil }
      let request = displayed[index]
      let title = label(request.title, bold: true); title.lineBreakMode = .byTruncatingTail; title.usesSingleLineMode = true
      let metadata = label("#\(request.number) · \(request.author) · \(request.draft ? "Draft" : request.state)", color: Theme.muted, size: 11)
      let stack = NSStackView(views: [title, metadata]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
      pin(stack, to: cell, inset: 7); cell.toolTip = request.title
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
    let index = requestsTable.selectedRow
    guard displayed.indices.contains(index), let client else { detailTask?.cancel(); selected = nil; detailReady = false; return }
    detailReady = false
    selected = displayed[index]; showRequestOverview(selected!); selectSection(0); loadDetails(selected!, client: client)
  }
  private func loadDetails(_ request: HostedRequest, client: HostingClient) {
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
      task?.cancel(); status.stringValue = "Validating account…"
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
            self.context = configuration; self.client = candidate; self.heading.stringValue = configuration.provider.requestTitle; self.reload()
          } else { self.status.stringValue += ". Open or clone a repository to view its requests." }
        } catch { if !Task.isCancelled { self?.status.stringValue = error.localizedDescription } }
      }
    } catch { status.stringValue = error.localizedDescription }
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
      do { try await operation(client); self?.writing = false; self?.remotePicker.isEnabled = true; self?.reload() }
      catch { self?.writing = false; self?.remotePicker.isEnabled = true; self?.status.stringValue = error.localizedDescription }
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
    } catch { status.stringValue = error.localizedDescription }
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
