import AppKit
import GitDeskCore

extension RepositoryController {
  func buildHosting() {
    hostingWorkspace.contextChanged = { [weak self] provider in
      guard let self else { return }
      let title = provider?.requestTitle ?? "Code Reviews"
      self.hostingTab.iconName = provider == .gitlab ? "gitlab" : "github"
      self.hostingTab.toolTip = title
      self.hostingTab.setAccessibilityLabel(title)
      if self.mode == "Reviews" { self.sectionTitle.stringValue = title }
    }
    addChild(hostingWorkspace)
    pin(hostingWorkspace.view, to: hostingBody)
    hostingWorkspace.checkout = { [weak self] context, request in self?.checkoutHostedRequest(context, request: request) }
    hostingWorkspace.showDiff = { [weak self] context, request, path in self?.diffHostedRequest(context, request: request, path: path) }
    pin(terminalWorkspace, to: terminalBody)
  }
  private func fetchHostedRequest(_ repo: GitRepository, context: HostingRepository, request: HostedRequest) throws -> (head: String, base: String) {
    let headRef = "refs/gitdesk/\(context.provider.rawValue)/\(request.number)/head"
    let baseRef = "refs/gitdesk/\(context.provider.rawValue)/\(request.number)/base"
    let remoteRef = context.provider == .github ? "refs/pull/\(request.number)/head" : "refs/merge-requests/\(request.number)/head"
    try repo.run(["fetch", "--", context.remote, "+\(remoteRef):\(headRef)", "+refs/heads/\(request.target):\(baseRef)"])
    let head = try repo.resolve(headRef)
    if !request.headSHA.isEmpty && head != request.headSHA { throw GitFailure("This request changed on the server. Refresh it before checking out or reviewing.") }
    let base = try repo.run(["merge-base", head, try repo.resolve(baseRef)]).trimmingCharacters(in: .whitespacesAndNewlines)
    return (head, base)
  }
  private func checkoutHostedRequest(_ context: HostingRepository, request: HostedRequest) {
    readHistory("Fetching review request", work: { repo in try self.fetchHostedRequest(repo, context: context, request: request) }) { [weak self] refs in
      guard let self else { return }
      let branch = "review/\(context.provider.rawValue)-\(request.number)-\(refs.head.prefix(8))"
      self.perform("Check out #\(request.number)", work: { repo in
        let existing = try repo.run(["show-ref", "--verify", "--hash", "refs/heads/" + branch], allowFailure: true).trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
          guard existing == refs.head else { throw GitFailure("The local review branch has changed. Choose another branch name before checking out this request.") }
          try repo.run(["switch", "--", branch])
        } else { try repo.run(["switch", "-c", branch, refs.head]) }
      })
    }
  }
  private func diffHostedRequest(_ context: HostingRepository, request: HostedRequest, path: String?) {
    readHistory("Loading review diff", work: { repo in
      let refs = try self.fetchHostedRequest(repo, context: context, request: request)
      return (refs.head, refs.base, try repo.compare(from: refs.base, to: refs.head))
    }) { [weak self] head, base, files in
      guard let self, let repo = self.repository else { return }
      guard !files.isEmpty else { self.statusLabel.stringValue = "No changed files in this request."; return }
      let diff = DiffWindowController(repository: repo, files: files, index: path.flatMap { value in files.firstIndex { $0.path == value } } ?? 0,
        commit: nil, comparison: (base, head))
      diff.controller.reviewComment = { [weak self] path, line, left in
        let oldPath = files.first(where: { $0.path == path })?.oldPath ?? path
        self?.hostingWorkspace.commentOnLine(context: context, request: request, path: path, oldPath: oldPath, line: line, left: left)
      }
      self.diffWindows.append(diff)
      diff.onClose = { [weak self, weak diff] in self?.diffWindows.removeAll { $0 === diff } }
      diff.showWindow(nil)
    }
  }
}
