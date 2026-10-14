import AppKit
import GitDeskCore

private final class HostingUIFixture: URLProtocol {
  private let lock = NSLock()
  private var stopped = false
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.path
    let github = request.url!.host!.contains("github")
    func review(_ number: Int) -> [String: Any] {
      github ? ["number": number, "node_id": "PR_fixture_\(number)", "title": "Demo review \(number)", "body": "Fixture data: review descriptions and discussions render natively.",
        "html_url": "https://github.example/team/demo/pull/\(number)", "user": ["login": "fixture-author"], "state": "open", "draft": number == 1,
        "head": ["ref": "feature/review-\(number)", "sha": "head\(number)"], "base": ["ref": "main", "sha": "base"]]
      : ["iid": number, "title": "Demo review \(number)", "description": "Fixture data: review descriptions and discussions render natively.",
        "web_url": "https://gitlab.example/team/demo/-/merge_requests/\(number)", "author": ["username": "fixture-author"], "state": "opened", "draft": number == 1,
        "source_branch": "feature/review-\(number)", "target_branch": "main", "sha": "head\(number)", "diff_refs": ["base_sha": "base", "start_sha": "base", "head_sha": "head\(number)"]]
    }
    let payload: Any
    let parameters = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let paging = parameters.contains { ($0.name == "q" || $0.name == "search") && ($0.value ?? "").contains("pagination") }
    let secondPage = parameters.contains { $0.name == "page" && $0.value == "2" }
    let empty = parameters.contains { ($0.name == "q" || $0.name == "search") && ($0.value ?? "").contains("does-not-exist") }
    if paging && path.hasSuffix("/search/issues") { payload = ["items": secondPage ? [review(99)] : (10..<60).map(review)] }
    else if paging && path.hasSuffix("/merge_requests") { payload = secondPage ? [review(99)] : (10..<60).map(review) }
    else if path.hasSuffix("/search/issues") { payload = ["items": empty ? [] : [review(1), review(2)]] }
    else if empty && path.hasSuffix("/merge_requests") { payload = [] }
    else if path.hasSuffix("/pulls") || path.hasSuffix("/merge_requests") { payload = [review(1), review(2)] }
    else if path.hasSuffix("/1") || path.hasSuffix("/2") { payload = review(path.hasSuffix("/1") ? 1 : 2) }
    else if path.hasSuffix("/files") { payload = [["filename": "Sources/Review.swift", "patch": "@@ -1 +1 @@\n-old\n+new", "status": "modified"]] }
    else if path.hasSuffix("/diffs") { payload = [["new_path": "Sources/Review.swift", "old_path": "Sources/Review.swift", "diff": "@@ -1 +1 @@\n-old\n+new"]] }
    else if path.hasSuffix("/comments") || path.hasSuffix("/notes") { payload = [["id": 9, "body": "Fixture discussion", github ? "user" : "author": [github ? "login" : "username": "fixture-reviewer"]]] }
    else if path.hasSuffix("/check-runs") { payload = ["check_runs": [["name": "Fixture CI", "status": "completed", "conclusion": "success"]]] }
    else if path.hasSuffix("/status") { payload = ["statuses": [["context": "build", "state": "success"]]] }
    else if path.hasSuffix("/approvals") { payload = ["approvals_left": 0, "approved_by": [["user": ["username": "fixture-reviewer"]]]] }
    else if path.hasSuffix("/graphql") { payload = ["data": ["repository": ["pullRequest": ["reviewThreads": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]]] }
    else { payload = [] }
    let result = try! JSONSerialization.data(withJSONObject: payload)
    DispatchQueue.global().asyncAfter(deadline: .now() + (path.hasSuffix("/1") ? 0.15 : 0.005)) { [weak self] in
      guard let self else { return }
      self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
      guard !stopped else { return }
      let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: result)
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

func runHostingChecks() throws {
  let originalTheme = Theme.current
  defer { Theme.current = originalTheme }
  Theme.current = .islandDark
  func waitFor(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(condition(), "Hosting UI fixture timed out")
  }
  func texts(_ view: NSView) -> [String] {
    (view as? NSTextView).map { [$0.string] } ?? view.subviews.flatMap(texts)
  }
  func buttons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
  }
  for provider in HostingProvider.allCases {
    let context = try HostingRepository(remoteURL: "https://\(provider.rawValue).example/team/demo.git", remote: "origin", provider: provider)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HostingUIFixture.self]
    let client = HostingClient(repository: context, token: "fixture-token", session: URLSession(configuration: configuration))
    let workspace = HostingWorkspace()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1174, height: 461), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = workspace; window.appearance = Theme.current.appearance
    NSLayoutConstraint.activate([workspace.view.widthAnchor.constraint(equalToConstant: 1174), workspace.view.heightAnchor.constraint(equalToConstant: 461)])
    workspace.navigationSplit.subviews[0].widthAnchor.constraint(equalToConstant: 587).isActive = true
    func allTexts() -> [String] { workspace.tabs.tabViewItems.compactMap(\.view).flatMap(texts) }
    workspace.useClient(client, repository: nil)
    waitFor { workspace.requestsTable.numberOfRows == 2 }
    precondition(!workspace.requestList.isHidden && workspace.requestOverview.isHidden)
    workspace.view.layoutSubtreeIfNeeded()
    precondition(workspace.navigationSplit.subviews[0].frame.width >= 340 && workspace.navigationSplit.subviews[0].frame.width <= 700)
    workspace.requestsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    precondition(!workspace.detailsVisible, "Selecting a request does not open details")
    workspace.openSelectedRequest()
    precondition(buttons(workspace.view).first { $0.title == "Check Out" }?.isEnabled == false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    workspace.requestsTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    workspace.openSelectedRequest()
    waitFor { workspace.filesTable.numberOfRows == 1 && allTexts().contains(where: { $0.contains("fixture-reviewer") }) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    precondition(allTexts().contains { $0.hasPrefix("#2 Demo review 2") }, "Cancelled request details must never replace the latest selection")
    precondition(!allTexts().contains { $0.hasPrefix("#1 Demo review 1") })
    precondition(buttons(workspace.view).first { $0.title == "Merge…" }?.isEnabled == true)
    precondition(workspace.requestList.isHidden && !workspace.requestOverview.isHidden,
      "Opening a request replaces the left list with its overview and changed files")
    workspace.filesTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    precondition(allTexts().contains { $0.contains("@@ -1 +1 @@") })
    workspace.view.layoutSubtreeIfNeeded()
    if let output = ProcessInfo.processInfo.environment["GITDESK_HOSTING_SCREENSHOTS"] {
      let directory = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for index in [0, 1, 2, 3] {
        workspace.selectSection(index); workspace.view.layoutSubtreeIfNeeded()
        let bitmap = workspace.view.bitmapImageRepForCachingDisplay(in: workspace.view.bounds)!
        workspace.view.cacheDisplay(in: workspace.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(provider.rawValue + "-\(index).png"))
      }
    }
    workspace.reload()
    waitFor { buttons(workspace.view).first { $0.title == "Check Out" }?.isEnabled == true && workspace.requestsTable.numberOfRows == 2 }
    precondition(workspace.detailsVisible, "Refreshing an opened request keeps its editor and reloads details")
    workspace.showRequestList()
    precondition(!workspace.requestList.isHidden && workspace.requestOverview.isHidden)
    workspace.requestsTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    workspace.openSelectedRequest()
    waitFor { buttons(workspace.view).first { $0.title == "Check Out" }?.isEnabled == true }
    precondition(!workspace.requestOverview.isHidden, "Back navigation allows reopening the same request")
    workspace.showRequestList()
    workspace.search.stringValue = "does-not-exist"
    workspace.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: workspace.search))
    waitFor { workspace.listEmptyMessage.stringValue.contains("matching filters") && workspace.requestsTable.numberOfRows == 0 }
    precondition(!workspace.detailsVisible)
    if let output = ProcessInfo.processInfo.environment["GITDESK_HOSTING_SCREENSHOTS"] {
      workspace.view.layoutSubtreeIfNeeded()
      let left = workspace.navigationSplit.subviews[0]
      let bitmap = left.bitmapImageRepForCachingDisplay(in: left.bounds)!
      left.cacheDisplay(in: left.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(provider.rawValue + "-empty.png"))
    }
    workspace.clearFilters()
    waitFor { workspace.requestsTable.numberOfRows == 2 }
    precondition(workspace.requestFilter.isEmpty && workspace.search.stringValue.isEmpty)
    workspace.search.stringValue = "pagination"
    workspace.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: workspace.search))
    waitFor { workspace.requestsTable.numberOfRows == 50 }
    workspace.view.layoutSubtreeIfNeeded()
    workspace.requestsTable.scrollRowToVisible(49)
    waitFor { workspace.requestsTable.numberOfRows == 51 }
    precondition(workspace.requestFilter.query == "pagination", "Lazy loading keeps the active server search")
    window.close()
  }
  print("Hosting UI: GitHub/GitLab lists, details, files, discussion, action states and stale-selection cancellation passed")
}
