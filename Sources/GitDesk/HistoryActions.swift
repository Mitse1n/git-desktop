import AppKit
import GitDeskCore

extension RepositoryController {
  func readHistory<T>(_ title: String, work: @escaping (GitRepository) throws -> T,
    completion: @escaping (T) -> Void)
  {
    guard let repo = repository, !isBusy else { return }
    let currentEpoch = epoch
    isBusy = true
    statusLabel.stringValue = title + "…"
    progress.startAnimation(nil)
    queue.async { [weak self] in
      let result = Result { try work(repo) }
      DispatchQueue.main.async {
        guard let self, self.epoch == currentEpoch else { return }
        self.isBusy = false
        self.progress.stopAnimation(nil)
        self.updateStatus()
        switch result {
        case .success(let value): completion(value)
        case .failure(let error): self.showError(error)
        }
      }
    }
  }
  func publishedHistoryNote(_ context: HistoryEditContext) -> String {
    context.publishedRefs.isEmpty ? "" : "\n\nPublished history: " + context.publishedRefs.joined(separator: ", ")
      + ". Updating those remote branches after rewriting requires a force push outside GitDesk."
  }
  func undoHistoryCommit(_ commit: Commit) {
    readHistory("Checking commit", work: { repo in
      (try repo.historyEditContext(from: commit.hash, expectedHead: commit.hash), try repo.changes(in: commit))
    }) { [weak self] context, files in
      guard let self, self.confirm("Undo Commit?",
        message: "Remove \(commit.shortHash) from the current branch. Files and existing staged changes stay intact; the undone changes remain staged and its message returns to the Commit panel."
          + self.publishedHistoryNote(context), action: "Undo Commit") else { return }
      let previousDraft = self.commitMessage.string
      self.perform("Undo commit", work: { try $0.undoCommit(commit.hash, expectedBranch: context.branch) }) {
        if !previousDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, previousDraft != commit.fullMessage {
          var history = UserDefaults.standard.stringArray(forKey: "commitMessages") ?? []
          history.removeAll { $0 == previousDraft }
          history.insert(previousDraft, at: 0)
          UserDefaults.standard.set(Array(history.prefix(20)), forKey: "commitMessages")
        }
        self.commitMessage.string = commit.fullMessage
        self.amendDraft = nil
        self.amendLoadToken += 1
        self.amend.state = .off
        self.selectedPaths = Set(files.map(\.path))
        self.setMode("Commit")
      }
    }
  }
  func editHistoryMessage(_ commit: Commit) {
    let head = snapshot?.branches.first(where: \.current)?.hash
    if head != commit.hash {
      startHistoryRebase(commit, action: .reword)
      return
    }
    readHistory("Checking commit", work: { try $0.historyEditContext(from: commit.hash, expectedHead: commit.hash) }) { [weak self] context in
      guard let self, let message = historyMessagePrompt("Edit Commit Message", message: commit.fullMessage) else { return }
      if !context.publishedRefs.isEmpty && !self.confirm("Rewrite Published Commit?",
        message: self.publishedHistoryNote(context), action: "Save Message") { return }
      self.perform("Edit commit message", work: { try $0.editHeadMessage(message, expectedHead: commit.hash, expectedBranch: context.branch) })
    }
  }
  func startHistoryRebase(_ commit: Commit, action: RebaseAction = .pick) {
    let from = (action == .squash || action == .fixup) ? commit.parents.first : commit.hash
    guard let from else { return }
    readHistory("Preparing history editor", work: { repo in
      (try repo.prepareRebase(from: from), try repo.historyEditContext(from: from, requireClean: true))
    }) { [weak self] plan, context in
      guard let self else { return }
      var initial = plan.entries
      if let index = initial.firstIndex(where: { $0.commit.hash == commit.hash }) {
        initial[index].action = action
      }
      guard let entries = RebaseEditor.present(initial, plan: plan, published: context.publishedRefs) else { return }
      self.perform("Rebase", work: { try $0.applyRebase(plan, entries: entries) })
    }
  }
  func navigateHistory(_ commit: Commit, toParent: Bool) {
    readHistory("Finding related commits", work: { repo in
      try toParent ? commit.parents.map { try repo.commit(at: $0) } : repo.children(of: commit.hash)
    }) { [weak self] commits in
      guard let self else { return }
      if commits.isEmpty {
        self.statusLabel.stringValue = toParent ? "No parent commit." : "No child commits in local history."
      } else if commits.count == 1 {
        self.revealHistoryCommit(commits[0])
      } else {
        let menu = NSMenu()
        for candidate in commits {
          menu.addItem(menuItem(candidate.shortHash + "  " + candidate.subject) { [weak self] in
            self?.revealHistoryCommit(candidate)
          })
        }
        self.popup(menu)
      }
    }
  }
  func revealHistoryCommit(_ commit: Commit) {
    func select(_ controller: RepositoryController, index: Int) {
      controller.setMode("Log")
      controller.logTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      controller.logTable.scrollRowToVisible(index)
    }
    if let index = snapshot?.commits.firstIndex(where: { $0.hash == commit.hash }) {
      select(self, index: index)
      return
    }
    guard let previous = snapshot else { return }
    var target = LogFilter()
    target.branch = commit.hash
    readHistory("Loading related commit", work: {
      let data = try $0.filteredSnapshot(from: previous, filter: target)
      return (data, RepositoryHistoryPresentation.prepare(data))
    }) { [weak self] data, presentation in
      guard let self else { return }
      self.loadToken += 1
      self.invalidateHistoryPage()
      self.filter = target
      self.loadedLogFilter = target
      self.logSearch.stringValue = ""
      self.datePopup.selectItem(at: 0)
      self.regexButton.contentTintColor = Theme.text
      self.caseButton.contentTintColor = Theme.text
      self.snapshot = data
      self.updateUI(presentation: presentation)
      if let index = data.commits.firstIndex(where: { $0.hash == commit.hash }) { select(self, index: index) }
    }
  }
  func createHistoryPatch(_ commit: Commit) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = commit.shortHash + ".patch"
    panel.title = "Create Patch"
    panel.message = commit.parents.count > 1
      ? "Export this merge's changes against its first parent as a binary-capable diff."
      : "Export this commit, including its message and author, as a Git-format patch."
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    readHistory("Exporting patch", work: { repo in
      try repo.patch(for: commit.hash).write(to: destination, options: .atomic)
    }) { [weak self] _ in
      self?.statusLabel.stringValue = "Patch saved: " + destination.path
    }
  }
  func showHistoryRepository(_ commit: Commit) {
    guard let repository else { return }
    let controller = RevisionBrowserWindowController(repository: repository, revision: commit)
    revisionWindows.append(controller)
    controller.onClose = { [weak self, weak controller] in self?.revisionWindows.removeAll { $0 === controller } }
    controller.showWindow(nil)
  }
  func skipRebaseCommit() {
    guard snapshot?.operation == "rebase", confirm("Skip Current Rebase Commit?",
      message: "Discard the patch currently being replayed, including its conflict resolution, and continue with the next commit.", action: "Skip Commit") else { return }
    perform("Skip rebase commit", work: { try $0.resumeRebase("skip") })
  }
  func abortHistoryOperation(_ operation: String) {
    guard confirm("Abort \(operation.capitalized)?",
      message: "Return to the state before \(operation). Resolution changes made during this operation will be discarded.", action: "Abort") else { return }
    perform("Abort \(operation)", work: { repo in
      if operation == "rebase" { try repo.resumeRebase("abort") }
      else { try repo.run([operation, "--abort"]) }
    })
  }
}
