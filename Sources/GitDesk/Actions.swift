import AppKit
import GitDeskCore

extension RepositoryController {
  func openPanel() {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "Select a local Git repository"
    panel.prompt = "Open Repository"
    if panel.runModal() == .OK, let url = panel.url { open(url) }
  }
  func showRecent() {
    let menu = NSMenu()
    menu.addItem(menuItem("Open Repository…") { [weak self] in self?.openPanel() })
    menu.addItem(menuItem("Clone Repository…") { [weak self] in self?.cloneRepository() })
    menu.addItem(menuItem("New Repository…") { [weak self] in self?.initializeRepository() })
    menu.addItem(.separator())
    var paths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    if let current = repository?.workingDirectory.path {
      paths.insert(current, at: 0)
    }
    var seen = Set<String>()
    paths = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
      .filter { seen.insert($0).inserted }
    for path in paths {
      let url = URL(fileURLWithPath: path)
      let current = repository?.workingDirectory.standardizedFileURL.resolvingSymlinksInPath() == url
      let item = menuItem(url.lastPathComponent) { [weak self] in self?.open(url) }
      item.image = ProjectIdentity.image(for: url)
      let text = NSMutableAttributedString(
        string: url.lastPathComponent,
        attributes: [
          .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Theme.text,
        ])
      text.append(
        NSAttributedString(
          string: "\n" + (path as NSString).abbreviatingWithTildeInPath,
          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.muted]))
      if current, let branch = snapshot?.currentBranch {
        text.append(
          NSAttributedString(
            string: "\n" + branch,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.muted]))
      }
      item.attributedTitle = text
      item.state = current ? .on : .off
      menu.addItem(item)
    }
    popup(menu, anchor: repoLabel)
  }
  func showRepositoryMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Open Repository…") { [weak self] in self?.openPanel() })
    menu.addItem(menuItem("Clone Repository…") { [weak self] in self?.cloneRepository() })
    menu.addItem(menuItem("New Repository…") { [weak self] in self?.initializeRepository() })
    menu.addItem(.separator())
    menu.addItem(
      menuItem("Manage Remotes…", enabled: repository != nil) { [weak self] in self?.manageRemotes()
      })
    menu.addItem(
      menuItem("Git Identity…", enabled: repository != nil) { [weak self] in self?.identity() })
    menu.addItem(
      menuItem("Stash Changes…", enabled: !(snapshot?.changes.isEmpty ?? true)) { [weak self] in
        self?.stashChanges()
      })
    menu.addItem(
      menuItem("Unstash Changes…", enabled: !(snapshot?.stashes.isEmpty ?? true)) { [weak self] in
        self?.showStashes()
      })
    menu.addItem(.separator())
    if let operation = snapshot?.operation {
      menu.addItem(
        menuItem("Continue \(operation)") { [weak self] in self?.continueOperation(operation) })
      menu.addItem(
        menuItem("Abort \(operation)") { [weak self] in
          self?.abortHistoryOperation(operation)
        })
    }
    if snapshot?.operation == "rebase" {
      menu.addItem(menuItem("Skip Current Rebase Commit…") { [weak self] in self?.skipRebaseCommit() })
    }
    menu.addItem(
      menuItem("Show in Finder", enabled: repository != nil) { [weak self] in
        if let url = self?.repository?.workingDirectory {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      })
    popup(menu)
  }
  func showBranchMenu() {
    guard repository != nil, !isBusy else { return }
    if let picker = headerBranchPicker { picker.close() }
    let picker = BranchPicker(owner: self)
    headerBranchPicker = picker
    picker.show(anchor: branchLabel)
  }

  func branchContextMenu() -> NSMenu {
    if let branch = selectedBranch { return branchMenu(branch) }
    if !selectedBranches.isEmpty {
      let branches = selectedBranches
      let menu = NSMenu()
      menu.autoenablesItems = false
      if branches.allSatisfy({ $0.kind == .local }), snapshot?.remotes.isEmpty == false {
        let update = menuItem("Update Selected", enabled: !isBusy && branches.allSatisfy { !$0.upstream.isEmpty }) { [weak self] in
          self?.perform("Update selected branches", work: { try $0.updateBranches(branches) })
        }
        update.image = NSImage(systemSymbolName: "arrow.down.left", accessibilityDescription: nil)
        update.toolTip = branches.allSatisfy { !$0.upstream.isEmpty }
          ? "Fetch upstreams; fast-forward non-current branches and merge updates into the current branch."
          : "Configure an upstream for every selected branch to update them."
        menu.addItem(update)
      }
      let delete = menuItem(branches.allSatisfy { $0.kind != .tag } ? "Delete Branches" : "Delete",
        enabled: !isBusy && !branches.contains(where: \.current)) { [weak self] in
        self?.deleteSelectedBranches(branches)
      }
      delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
      delete.keyEquivalent = "\u{8}"
      delete.keyEquivalentModifierMask = .command
      menu.addItem(delete)
      return menu
    }
    let menu = NSMenu()
    menu.addItem(
      menuItem("New Branch…", enabled: repository != nil) { [weak self] in self?.newBranch() })
    menu.addItem(
      menuItem("Show All Branches") { [weak self] in
        self?.filter.branch = nil
        self?.refresh(logOnly: true)
      })
    return menu
  }
  func branchMenu(_ branch: Branch) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(
      menuItem("Checkout", enabled: !branch.current) { [weak self] in
        self?.perform("Checkout \(branch.name)", work: { try $0.checkout(branch) })
      })
    menu.addItem(
      menuItem("New Branch from '\(branch.name)'…") { [weak self] in
        self?.newBranch(start: branch.fullRef)
      })
    menu.addItem(
      menuItem("Show in Log") { [weak self] in
        self?.filter.branch = branch.fullRef
        self?.setMode("Log")
        self?.refresh(logOnly: true)
      })
    menu.addItem(
      menuItem("Compare with '\(snapshot?.currentBranch ?? "HEAD")'", enabled: !branch.current) {
        [weak self] in self?.compareBranch(branch)
      })
    menu.addItem(
      menuItem("Show Diff with Working Tree") { [weak self] in self?.diffWithWorkingTree(branch) })
    menu.addItem(.separator())
    menu.addItem(
      menuItem("Merge '\(branch.name)' into Current", enabled: !branch.current) { [weak self] in
        guard let self,
          self.confirm(
            "Merge Branch",
            message: "Merge \(branch.name) into \(self.snapshot?.currentBranch ?? "HEAD")?",
            action: "Merge")
        else { return }
        self.perform(
          "Merge",
          work: { repo in try repo.run(["merge", "--no-edit", try repo.resolve(branch.fullRef)]) })
      })
    menu.addItem(
      menuItem("Rebase Current onto '\(branch.name)'", enabled: !branch.current) { [weak self] in
        guard let self,
          self.confirm(
            "Rebase Branch",
            message:
              "Replay current branch commits on \(branch.name). This rewrites local commit history.",
            action: "Rebase")
        else { return }
        self.perform(
          "Rebase", work: { repo in try repo.run(["rebase", try repo.resolve(branch.fullRef)]) })
      })
    menu.addItem(menuItem("New Worktree…") { [weak self] in self?.newWorktree(branch) })
    menu.addItem(.separator())
    menu.addItem(
      menuItem(favoriteRefs.contains(branch.fullRef) ? "Unmark as Favorite" : "Mark as Favorite") {
        [weak self] in self?.toggleFavorite(branch)
      })
    if branch.kind == .local {
      menu.addItem(menuItem("Rename…") { [weak self] in self?.renameBranch(branch) })
    }
    menu.addItem(
      menuItem("Delete", enabled: !branch.current) { [weak self] in self?.deleteBranch(branch) })
    return menu
  }
  func newBranch(start: String = "HEAD") {
    let checkout = NSButton(checkboxWithTitle: "Checkout branch", target: nil, action: nil)
    checkout.state = .on
    styleCheckbox(checkout)
    guard
      let values = prompt(
        "New Branch", fields: [("Name", "")],
        extra: labeledCheckbox(checkout, title: "Checkout branch")),
      !values[0].isEmpty
    else { return }
    perform(
      "Create branch",
      work: { try $0.createBranch(values[0], start: start, checkout: checkout.state == .on) })
  }
  func renameBranch(_ branch: Branch) {
    guard let values = prompt("Rename Branch", fields: [("New name", branch.name)]),
      !values[0].isEmpty
    else { return }
    perform(
      "Rename branch",
      work: { repo in
        try repo.run(["check-ref-format", "--branch", values[0]])
        try repo.run(["branch", "-m", branch.name, values[0]])
      },
      completion: { [weak self] in
        if self?.filter.branch == branch.fullRef { self?.filter.branch = "refs/heads/" + values[0] }
      })
  }
  func deleteSelectedBranches(_ branches: [Branch]) {
    guard !branches.isEmpty, !branches.contains(where: \.current),
      confirm("Delete Selected References?",
        message: branches.map(\.name).joined(separator: "\n")
          + "\n\nUnmerged local branches will not be deleted. Remote-tracking references are removed locally.",
        action: "Delete") else { return }
    perform("Delete selected references", work: { try $0.deleteBranches(branches) }, completion: { [weak self] in
      if let ref = self?.filter.branch, branches.contains(where: { $0.fullRef == ref }) {
        self?.filter.branch = nil
      }
    })
  }
  func deleteBranch(_ branch: Branch? = nil) {
    if branch == nil, selectedBranches.count > 1 { deleteSelectedBranches(selectedBranches); return }
    guard let branch = branch ?? selectedBranch, !branch.current,
      confirm(
        "Delete '\(branch.name)'?",
        message: branch.kind == .local
          ? "Git will refuse to delete an unmerged branch. Commits remain accessible through the reflog."
          : "Remove this local \(branch.kind.rawValue) reference.", action: "Delete")
    else { return }
    perform(
      "Delete branch",
      work: { repo in
        switch branch.kind {
        case .local: try repo.run(["branch", "-d", "--", branch.name])
        case .remote: try repo.run(["branch", "-rd", "--", branch.name])
        case .tag: try repo.run(["tag", "-d", "--", branch.name])
        }
      },
      completion: { [weak self] in
        if self?.filter.branch == branch.fullRef { self?.filter.branch = nil }
      })
  }
  func checkoutRevision() {
    guard let values = prompt("Checkout Tag or Revision", fields: [("Hash, branch, or tag", "")]),
      !values[0].isEmpty
    else { return }
    perform(
      "Checkout revision",
      work: { repo in try repo.run(["switch", "--detach", try repo.resolve(values[0])]) })
  }
  func newWorktree(_ branch: Branch) {
    guard
      let values = prompt("New Worktree", fields: [("Directory", ""), ("New branch name", "")]),
      !values[0].isEmpty, !values[1].isEmpty
    else { return }
    perform(
      "Create worktree",
      work: { repo in
        try repo.run(["check-ref-format", "--branch", values[1]])
        try repo.run([
          "worktree", "add", "-b", values[1], values[0], try repo.resolve(branch.fullRef),
        ])
      })
  }
  func compareBranch(_ branch: Branch? = nil) {
    guard let branch = branch ?? selectedBranch else { return }
    compareRevisions(from: "HEAD", to: branch.fullRef, title: "HEAD ↔ \(branch.name)")
  }
  func compareRevisions(from: String, to: String, title: String) {
    guard let repo = repository else { return }
    detailToken += 1
    let token = detailToken
    queue.async { [weak self] in
      do {
        let a = try repo.resolve(from)
        let b = try repo.resolve(to)
        let files = try repo.compare(from: a, to: b)
        DispatchQueue.main.async {
          guard let self, token == self.detailToken else { return }
          self.comparison = (a, b)
          self.detailFiles = files
          self.rebuildDetailFiles()
          self.detailsText.string = title + "\n\n\(files.count) changed files"
          self.setMode("Log")
          if !files.isEmpty { self.openDiff(files: files, index: 0, comparison: (a, b)) }
        }
      } catch { DispatchQueue.main.async { self?.showError(error) } }
    }
  }
  func diffWithWorkingTree(_ branch: Branch) {
    guard let repo = repository else { return }
    queue.async { [weak self] in
      do {
        let hash = try repo.resolve(branch.fullRef)
        let files = GitRepository.parseNameStatus(
          try repo.runData(["diff", "--name-status", "-z", hash]))
        DispatchQueue.main.async {
          guard let self else { return }
          if files.isEmpty {
            self.statusLabel.stringValue = "Working tree is identical to \(branch.name)"
          } else {
            self.openDiff(files: files, index: 0, comparison: (hash, "WORKTREE"))
          }
        }
      } catch { DispatchQueue.main.async { self?.showError(error) } }
    }
  }
  func commitContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    guard let commit = selectedCommit else { return menu }
    menu.addItem(
      menuItem("Copy Revision Number") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
      })
    menu.addItem(
      menuItem("Copy Commit Message") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
          commit.subject + (commit.body.isEmpty ? "" : "\n\n" + commit.body), forType: .string)
      })
    let single = logTable.selectedRowIndexes.count == 1
    let idle = !isBusy && snapshot?.operation == nil
    let onBranch = snapshot?.branches.contains(where: \.current) == true
    let head = snapshot?.branches.first(where: \.current)?.hash
    let editable = single && idle && onBranch && currentBranchHistory.contains(commit.hash)
    menu.addItem(menuItem("Create Patch…", enabled: single && !isBusy) { [weak self] in self?.createHistoryPatch(commit) })
    menu.addItem(.separator())
    menu.addItem(menuItem("Show Diff") { [weak self] in self?.showDiff() })
    menu.addItem(menuItem("Show Repository at Revision", enabled: single) { [weak self] in self?.showHistoryRepository(commit) })
    menu.addItem(
      menuItem("Compare with Local") { [weak self] in
        self?.compareRevisions(from: commit.hash, to: "HEAD", title: commit.shortHash + " ↔ HEAD")
      })
    if logTable.selectedRowIndexes.count == 2, let commits = snapshot?.commits {
      let indices = Array(logTable.selectedRowIndexes)
      let a = commits[indices[1]]
      let b = commits[indices[0]]
      menu.addItem(
        menuItem("Compare Selected Commits") { [weak self] in
          self?.compareRevisions(from: a.hash, to: b.hash, title: a.shortHash + " ↔ " + b.shortHash)
        })
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("New Branch…") { [weak self] in self?.newBranch(start: commit.hash) })
    menu.addItem(menuItem("New Tag…") { [weak self] in self?.newTag(commit) })
    menu.addItem(
      menuItem("Checkout Revision") { [weak self] in
        self?.perform("Checkout", work: { try $0.run(["switch", "--detach", commit.hash]) })
      })
    menu.addItem(.separator())
    menu.addItem(menuItem("Cherry-Pick") { [weak self] in self?.commitAction("cherry-pick") })
    menu.addItem(menuItem("Revert Commit") { [weak self] in self?.commitAction("revert") })
    menu.addItem(menuItem("Reset Current Branch to Here…") { [weak self] in self?.resetTo(commit) })
    menu.addItem(menuItem("Undo Commit…", enabled: editable && head == commit.hash) { [weak self] in self?.undoHistoryCommit(commit) })
    menu.addItem(.separator())
    menu.addItem(menuItem("Edit Commit Message…", enabled: editable && (commit.parents.count <= 1 || head == commit.hash)) { [weak self] in self?.editHistoryMessage(commit) })
    menu.addItem(menuItem("Fixup…", enabled: editable && commit.parents.count == 1) { [weak self] in self?.startHistoryRebase(commit, action: .fixup) })
    menu.addItem(menuItem("Squash Into…", enabled: editable && commit.parents.count == 1) { [weak self] in self?.startHistoryRebase(commit, action: .squash) })
    menu.addItem(menuItem("Drop Commit…", enabled: editable && commit.parents.count <= 1) { [weak self] in self?.startHistoryRebase(commit, action: .drop) })
    menu.addItem(menuItem("Interactively Rebase from Here…", enabled: editable && commit.parents.count <= 1) { [weak self] in self?.startHistoryRebase(commit) })
    menu.addItem(.separator())
    menu.addItem(menuItem("Go to Child Commit", enabled: single && !isBusy) { [weak self] in self?.navigateHistory(commit, toParent: false) })
    menu.addItem(menuItem("Go to Parent Commit", enabled: single && !isBusy && !commit.parents.isEmpty) { [weak self] in self?.navigateHistory(commit, toParent: true) })
    return menu
  }
  func commitAction(_ operation: String) {
    guard let commit = selectedCommit else { return }
    let mainline = commit.parents.count > 1 ? ["-m", "1"] : []
    guard
      confirm(
        operation == "revert" ? "Revert Commit" : "Cherry-Pick Commit",
        message: "\(commit.shortHash)  \(commit.subject)"
          + (mainline.isEmpty ? "" : "\nThis merge will use its first parent as the mainline."),
        action: operation == "revert" ? "Revert" : "Cherry-Pick")
    else { return }
    perform(operation, work: { try $0.run([operation] + mainline + [commit.hash]) })
  }
  func newTag(_ commit: Commit) {
    guard let values = prompt("New Tag", fields: [("Name", ""), ("Annotation (optional)", "")]),
      !values[0].isEmpty
    else { return }
    perform(
      "Create tag",
      work: { repo in
        try repo.run(["check-ref-format", "refs/tags/" + values[0]])
        try repo.run(
          values[1].isEmpty
            ? ["tag", "--", values[0], commit.hash]
            : ["tag", "-a", "-m", values[1], "--", values[0], commit.hash])
      })
  }
  func resetTo(_ commit: Commit) {
    let type = NSPopUpButton()
    type.addItems(withTitles: [
      "Soft — keep changes staged", "Mixed — keep changes unstaged",
      "Hard — discard tracked changes",
    ])
    type.selectItem(at: 1)
    guard prompt("Reset Current Branch", fields: [], extra: type) != nil else { return }
    let option = ["--soft", "--mixed", "--hard"][type.indexOfSelectedItem]
    guard
      confirm(
        "Reset to \(commit.shortHash)?",
        message: option == "--hard"
          ? "This moves the branch and permanently discards tracked working-tree changes."
          : "This moves the current branch to the selected commit. File changes are preserved.",
        action: "Reset")
    else { return }
    perform("Reset", work: { try $0.run(["reset", option, commit.hash]) })
  }
  func workingSelection() -> [FileChange] {
    let files = snapshot?.changes ?? []
    if !changesTable.selectedRowIndexes.isEmpty {
      let chosen = Set(
        changesTable.selectedRowIndexes.flatMap {
          $0 < workingRows.count ? workingRows[$0].files.map(\.path) : []
        })
      return files.filter { chosen.contains($0.path) }
    }
    return files.filter { selectedPaths.contains($0.path) }
  }
  func fileContextMenu(working: Bool) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let selection = working ? workingSelection() : selectedDetailFiles
    let paths = working ? Array(Set(changesTable.selectedRowIndexes.flatMap {
      workingRows.indices.contains($0) ? workingRows[$0].paths : []
    })).sorted() : selection.map(\.path)
    let canModify = !selection.isEmpty && !isBusy
    menu.addItem(
      menuItem("Show Diff", enabled: !selection.isEmpty) { [weak self] in working ? self?.showWorkingDiff() : self?.showDiff() })
    if working {
      menu.addItem(
        menuItem("Stage", enabled: canModify) { [weak self] in
          guard let self else { return }
          let files = self.workingSelection()
          if !files.isEmpty { self.perform("Stage files", work: { try $0.stage(files) }) }
        })
      menu.addItem(
        menuItem("Unstage", enabled: canModify) { [weak self] in
          guard let self else { return }
          let files = self.workingSelection()
          if !files.isEmpty { self.perform("Unstage files", work: { try $0.unstage(files) }) }
        })
      menu.addItem(menuItem("Rollback…", enabled: canModify) { [weak self] in self?.rollback() })
      if workingSelection().contains(where: \.isConflicted) {
        menu.addItem(menuItem("Resolve Conflicts…") { [weak self] in self?.resolveConflicts() })
        menu.addItem(menuItem("Accept Ours") { [weak self] in self?.acceptConflict("ours") })
        menu.addItem(menuItem("Accept Theirs") { [weak self] in self?.acceptConflict("theirs") })
        menu.addItem(
          menuItem("Mark Resolved") { [weak self] in
            guard let self else { return }
            let files = self.workingSelection()
            self.perform("Mark resolved", work: { try $0.stage(files) })
          })
      }
    }
    menu.addItem(
      menuItem("Copy Path", enabled: !paths.isEmpty) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
      })
    menu.addItem(
      menuItem("Show in Finder", enabled: !paths.isEmpty) { [weak self] in
        guard let self, let repo = self.repository else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
          paths.map { repo.workingDirectory.appendingPathComponent($0) })
      })
    return menu
  }
  func rollback() {
    let files = workingSelection()
    guard !files.isEmpty else { return }
    guard
      confirm(
        "Rollback \(files.count) file(s)?",
        message: "Tracked changes will be discarded. Unversioned files will be moved to Trash.",
        action: "Rollback")
    else { return }
    perform(
      "Rollback",
      work: { repo in
        let tracked = files.filter { !$0.isUntracked }
        if !tracked.isEmpty { try repo.discard(tracked) }
        for file in files where file.isUntracked {
          try FileManager.default.trashItem(
            at: repo.workingDirectory.appendingPathComponent(file.path), resultingItemURL: nil)
        }
      })
  }
  @objc func amendChanged() {
    amendLoadToken += 1
    let request = amendLoadToken
    guard amend.state == .on else {
      if let draft = amendDraft { commitMessage.string = draft }
      amendDraft = nil
      return
    }
    guard let repo = repository else { return }
    let initialMessage = commitMessage.string
    if amendDraft == nil { amendDraft = initialMessage }
    let currentEpoch = epoch
    queue.async { [weak self] in
      let result = Result { try repo.commit(at: "HEAD") }
      DispatchQueue.main.async {
        guard let self, self.epoch == currentEpoch, self.amendLoadToken == request,
          self.amend.state == .on, self.commitMessage.string == initialMessage else { return }
        switch result {
        case .success(let commit): self.commitMessage.string = commit.fullMessage
        case .failure(let error): self.statusLabel.stringValue = error.localizedDescription
        }
      }
    }
  }
  func commitChanges(push shouldPush: Bool) {
    let files = snapshot?.changes.filter { selectedPaths.contains($0.path) } ?? []
    let message = commitMessage.string
    let isAmend = amend.state == .on
    let author = commitAuthor
    let signOff = commitSignOff
    if isAmend
      && !confirm(
        "Amend Last Commit?",
        message:
          "Replace the latest commit with the selected changes and message. This rewrites its revision number.",
        action: "Amend")
    {
      return
    }
    perform(
      isAmend ? "Amend commit" : "Commit",
      work: { try $0.commit(message: message, changes: files, amend: isAmend,
        author: author, signOff: signOff) },
      completion: { [weak self] in
        guard let self else { return }
        var history = UserDefaults.standard.stringArray(forKey: "commitMessages") ?? []
        history.removeAll { $0 == message }
        history.insert(message, at: 0)
        UserDefaults.standard.set(Array(history.prefix(20)), forKey: "commitMessages")
        self.commitMessage.string = ""
        self.amendDraft = nil
        self.amendLoadToken += 1
        self.amend.state = .off
        self.selectedPaths = []
        if shouldPush { self.push() }
      })
  }
  func messageHistory() {
    let menu = NSMenu()
    for message in UserDefaults.standard.stringArray(forKey: "commitMessages") ?? [] {
      menu.addItem(
        menuItem(String(message.prefix(80))) { [weak self] in self?.commitMessage.string = message }
      )
    }
    popup(menu)
  }
  func stashChanges() {
    guard let values = prompt("Stash Changes", fields: [("Message", "")]) else { return }
    perform(
      "Stash",
      work: {
        try $0.run([
          "stash", "push", "--include-untracked", "-m",
          values[0].isEmpty ? "GitDesk stash" : values[0],
        ])
      })
  }
  func showStashes() {
    let menu = NSMenu()
    menu.addItem(
      menuItem("Stash Changes…", enabled: !(snapshot?.changes.isEmpty ?? true)) { [weak self] in
        self?.stashChanges()
      })
    menu.addItem(.separator())
    for stash in snapshot?.stashes ?? [] {
      let ref = String(stash.split(separator: ":", maxSplits: 1)[0])
      let item = NSMenuItem(title: stash, action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      submenu.addItem(
        menuItem("Apply") { [weak self] in
          self?.perform("Apply stash", work: { try $0.run(["stash", "apply", ref]) })
        })
      submenu.addItem(
        menuItem("Pop") { [weak self] in
          self?.perform("Pop stash", work: { try $0.run(["stash", "pop", ref]) })
        })
      submenu.addItem(
        menuItem("Show Diff") { [weak self] in
          self?.compareRevisions(from: ref + "^1", to: ref, title: stash)
        })
      submenu.addItem(
        menuItem("Drop…") { [weak self] in
          guard let self, self.confirm("Drop Stash?", message: stash, action: "Drop") else {
            return
          }
          self.perform("Drop stash", work: { try $0.run(["stash", "drop", ref]) })
        })
      item.submenu = submenu
      menu.addItem(item)
    }
    popup(menu)
  }
  func remoteAction(_ action: String) {
    guard !(snapshot?.remotes.isEmpty ?? true) else {
      statusLabel.stringValue = "No remotes configured. Use Repository Actions → Manage Remotes."
      return
    }
    perform(
      action.capitalized,
      work: {
        try $0.run(action == "fetch" ? ["fetch", "--all", "--prune"] : ["pull", "--ff-only"])
      })
  }
  func push() {
    guard let data = snapshot, !data.remotes.isEmpty,
      data.branches.contains(where: \.current)
    else {
      statusLabel.stringValue = "Configure a remote and checkout a branch before pushing."
      return
    }
    readHistory("Preparing push", work: { try $0.defaultPushTarget() }) { [weak self] target in
      guard let self else { return }
      let remote = NSPopUpButton()
      remote.addItems(withTitles: data.remotes)
      remote.selectItem(withTitle: target.remote)
      guard let values = self.prompt("Push Commits",
        fields: [("Remote branch / ref", target.branch)], extra: remote),
        !values[0].isEmpty else { return }
      let remoteName = remote.titleOfSelectedItem ?? target.remote
      self.perform("Push", work: { try $0.push(remote: remoteName, branch: values[0]) })
    }
  }

  func manageRemotes() {
    let menu = NSMenu()
    menu.addItem(
      menuItem("Add Remote…") { [weak self] in
        guard let self,
          let values = self.prompt("Add Remote", fields: [("Name", "origin"), ("URL", "")]),
          !values[0].isEmpty, !values[1].isEmpty
        else { return }
        self.perform("Add remote", work: { try $0.run(["remote", "add", values[0], values[1]]) })
      })
    for remote in snapshot?.remotes ?? [] {
      let item = NSMenuItem(title: remote, action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      submenu.addItem(
        menuItem("Edit URL…") { [weak self] in
          guard let self else { return }
          self.queue.async { [weak self] in
            let url = (try? self?.repository?.run(["remote", "get-url", remote])) ?? ""
            DispatchQueue.main.async {
              guard let self,
                let values = self.prompt(
                  "Edit Remote",
                  fields: [("URL", url.trimmingCharacters(in: .whitespacesAndNewlines))])
              else { return }
              self.perform(
                "Edit remote", work: { try $0.run(["remote", "set-url", remote, values[0]]) })
            }
          }
        })
      submenu.addItem(
        menuItem("Remove…") { [weak self] in
          guard let self,
            self.confirm(
              "Remove Remote?",
              message: remote + " and its tracking references will be removed locally.",
              action: "Remove")
          else { return }
          self.perform("Remove remote", work: { try $0.run(["remote", "remove", remote]) })
        })
      item.submenu = submenu
      menu.addItem(item)
    }
    popup(menu)
  }
  func identity() {
    guard let values = prompt("Repository Git Identity", fields: [("Name", ""), ("Email", "")]),
      !values[0].isEmpty, !values[1].isEmpty
    else { return }
    perform(
      "Save identity",
      work: {
        try $0.run(["config", "--local", "user.name", values[0]])
        try $0.run(["config", "--local", "user.email", values[1]])
      })
  }
  func continueOperation(_ operation: String) {
    if operation == "merge" {
      setMode("Commit")
      statusLabel.stringValue = "Commit the merge after resolving all conflicts."
      return
    }
    perform(
      "Continue \(operation)",
      work: { repo in
        if operation == "rebase" { try repo.resumeRebase("continue") }
        else { try repo.run(["-c", "core.editor=true", operation, "--continue"]) }
      })
  }
  func acceptConflict(_ side: String) {
    let files = workingSelection().filter(\.isConflicted)
    guard !files.isEmpty,
      confirm(
        "Accept \(side.capitalized)?",
        message:
          "Replace \(files.count) conflicted file(s) with the \(side) version and stage the result.",
        action: "Accept")
    else { return }
    perform(
      "Resolve conflicts",
      work: {
        try $0.acceptConflicts(files, side: side == "ours" ? .ours : .theirs)
      })
  }
  func resolveConflicts() {
    guard let repo = repository else { return }
    for file in workingSelection() where file.isConflicted {
      let controller = ConflictWindowController(repository: repo, file: file)
      controller.onResolve = { [weak self] in self?.refresh() }
      controller.onClose = { [weak self, weak controller] in
        self?.conflictWindows.removeAll { $0 === controller }
      }
      controller.showWindow(nil)
      conflictWindows.append(controller)
    }
  }
  func toggleBranches() {
    branchHidden.toggle()
    branchPanel.isHidden = branchHidden
    split.adjustSubviews()
  }
  func detailsOptions(anchor: NSView? = nil) {
    let menu = NSMenu()
    menu.addItem(NSMenuItem.sectionHeader(title: "Group By"))
    menu.addItem(option("Directory", checked: groupDetailDirectories, key: "p") { [weak self] in
      self?.groupDetailDirectories.toggle()
      self?.rebuildDetailFiles()
    })
    menu.addItem(option("Module", checked: groupDetailModules, key: "m") { [weak self] in
      self?.groupDetailModules.toggle()
      self?.rebuildDetailFiles()
    })
    menu.addItem(.separator())
    menu.addItem(option("Show Details", checked: showDetails) { [weak self] in
      self?.showDetails.toggle()
      self?.updateDetailVisibility()
    })
    popup(menu, anchor: anchor)
  }
  func updateDetailVisibility() {
    detailTextArea?.isHidden = !showDetails
    detailsSplit?.adjustSubviews()
  }
  private func option(_ title: String, checked: Bool, key: String = "",
    handler: @escaping () -> Void) -> NSMenuItem {
    let item = menuItem(title, handler: handler)
    item.state = checked ? .on : .off
    if !key.isEmpty { item.keyEquivalent = key; item.keyEquivalentModifierMask = .control }
    return item
  }
  func reloadLogAppearance() {
    displayedCurrentBranchHighlight = shouldHighlightCurrentBranch
    logTable.reloadKeepingSelection()
  }
  func toggleLongGraphEdges() {
    showLongGraphEdges.toggle()
    guard let data = snapshot else { return }
    let showLongEdges = showLongGraphEdges
    let prior = historyPresentation
    let currentEpoch = epoch
    queue.async { [weak self] in
      let presentation = RepositoryHistoryPresentation.prepare(data, reusing: prior, showLongEdges: showLongEdges)
      DispatchQueue.main.async {
        guard let self, self.epoch == currentEpoch, self.snapshot.map({ presentation.matches($0) }) == true,
          self.showLongGraphEdges == showLongEdges else { return }
        let origin = self.logTable.enclosingScrollView?.contentView.bounds.origin
        self.updateUI(presentation: presentation)
        if let origin, let scroll = self.logTable.enclosingScrollView {
          scroll.contentView.scroll(to: origin)
          scroll.reflectScrolledClipView(scroll.contentView)
        }
      }
    }
  }
  func logViewOptions(anchor: NSView? = nil) {
    let menu = NSMenu()
    menu.addItem(NSMenuItem.sectionHeader(title: "Show"))
    menu.addItem(option("Compact References View", checked: compactReferences) { [weak self] in
      self?.compactReferences.toggle()
      self?.reloadLogAppearance()
    })
    menu.addItem(option("Long Edges", checked: showLongGraphEdges) { [weak self] in
      self?.toggleLongGraphEdges()
    })
    menu.addItem(option("Tag Names", checked: showLogTagNames) { [weak self] in
      self?.showLogTagNames.toggle()
      self?.reloadLogAppearance()
    })
    menu.addItem(option("References on the Left", checked: referencesOnLeft) { [weak self] in
      self?.referencesOnLeft.toggle()
      self?.reloadLogAppearance()
    })
    let columns = NSMenu()
    for (id, title) in [("author", "Author"), ("date", "Date")] {
      guard let column = logTable.tableColumn(withIdentifier: .init(id)) else { continue }
      columns.addItem(option(title, checked: !column.isHidden) { [weak self, weak column] in
        guard let self, let column else { return }
        column.isHidden.toggle()
        UserDefaults.standard.set(column.isHidden, forKey: "logHideColumn." + id)
        self.logTable.fitColumns()
        self.reloadLogAppearance()
      })
    }
    let columnItem = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
    columnItem.submenu = columns
    menu.addItem(columnItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem.sectionHeader(title: "Highlight"))
    menu.addItem(option("My Commits", checked: highlightMyCommits) { [weak self] in
      self?.highlightMyCommits.toggle()
      self?.reloadLogAppearance()
    })
    menu.addItem(option("Merge Commits", checked: highlightMergeCommits) { [weak self] in
      self?.highlightMergeCommits.toggle()
      self?.reloadLogAppearance()
    })
    menu.addItem(option("Current Branch", checked: highlightCurrentBranch) { [weak self] in
      self?.highlightCurrentBranch.toggle()
      self?.reloadLogAppearance()
    })
    popup(menu, anchor: anchor)
  }
  func branchViewOptions(anchor: NSView? = nil) {
    let menu = NSMenu()
    menu.addItem(NSMenuItem.sectionHeader(title: "On Single Click"))
    menu.addItem(option("Update Branch Filter", checked: branchClickUpdatesFilter) { [weak self] in
      self?.branchClickUpdatesFilter.toggle()
    })
    menu.addItem(option("Navigate Log to Branch Head", checked: branchClickNavigates) { [weak self] in
      self?.branchClickNavigates.toggle()
    })
    menu.addItem(.separator())
    menu.addItem(option("Group by Directory", checked: groupBranches) { [weak self] in
      self?.groupBranches.toggle()
      self?.rebuildBranches()
    })
    menu.addItem(option("Show Tags", checked: showTags) { [weak self] in
      self?.showTags.toggle()
      self?.rebuildBranches()
    })
    menu.addItem(option("Show Favorite Branches Only", checked: favoriteOnly) { [weak self] in
      self?.favoriteOnly.toggle()
      self?.rebuildBranches()
    })
    popup(menu, anchor: anchor)
  }
  func setBranchFavorites(_ branches: [Branch], favorite: Bool) {
    var refs = favoriteRefs
    for branch in branches {
      if favorite { refs.insert(branch.fullRef) } else { refs.remove(branch.fullRef) }
    }
    favoriteRefs = refs
    rebuildBranches()
  }
  func toggleSelectedBranchFavorites() {
    let branches = selectedBranches
    guard !branches.isEmpty else { return }
    setBranchFavorites(branches, favorite: !branches.allSatisfy { favoriteRefs.contains($0.fullRef) })
  }
  func toggleFavorite(_ branch: Branch) {
    setBranchFavorites([branch], favorite: !favoriteRefs.contains(branch.fullRef))
  }
  @objc func branchSingleClick() {
    // Extending a selection must not jump the log or replace its filter.
    guard branchOutline.selectedRowIndexes.count == 1,
      NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty != false,
      let node = branchOutline.item(atRow: branchOutline.clickedRow) as? BranchNode,
      node.branch != nil || node.title == "HEAD (Current Branch)" else { return }
    let ref = node.branch?.fullRef ?? "HEAD"
    if branchClickUpdatesFilter {
      filter.branch = ref
      refresh(logOnly: true)
    }
    if branchClickNavigates {
      readHistory("Finding branch head", work: { try $0.commit(at: ref) }) { [weak self] in
        self?.revealHistoryCommit($0)
      }
    }
  }
  func filterMenu(anchor: NSView? = nil) {
    let menu = NSMenu()
    menu.addItem(menuItem("Filter by Path…") { [weak self] in
      guard let self, let values = self.prompt("Paths Filter",
        fields: [("Repository-relative path", self.filter.path ?? "")]) else { return }
      self.filter.path = values[0].isEmpty ? nil : values[0]
      self.refresh(logOnly: true)
    })
    menu.addItem(option("First Parent Only", checked: filter.firstParent) { [weak self] in
      self?.filter.firstParent.toggle()
      self?.refresh(logOnly: true)
    })
    menu.addItem(menuItem("Clear All Filters") { [weak self] in
      guard let self else { return }
      self.debounce?.cancel()
      self.filter = LogFilter()
      self.logSearch.stringValue = ""
      self.datePopup.selectItem(at: 0)
      self.regexButton.contentTintColor = Theme.text
      self.caseButton.contentTintColor = Theme.text
      self.refresh(logOnly: true)
    })
    menu.addItem(.separator())
    menu.addItem(menuItem(branchHidden ? "Show Git Branches" : "Hide Git Branches") { [weak self] in
      self?.toggleBranches()
    })
    menu.addItem(menuItem("Load More History", enabled: snapshot?.hasMoreCommits == true
      && !isBusy && !isRefreshing && !isLoadingMoreHistory) { [weak self] in
      self?.loadMoreHistory()
    })
    popup(menu, anchor: anchor)
  }
  func focusSearch() {
    setMode("Log")
    view.window?.makeFirstResponder(logSearch)
  }
  func goTo() {
    guard let values = prompt("Go to Hash / Branch / Tag", fields: [("Revision", "")]),
      !values[0].isEmpty, let repo = repository
    else { return }
    let showLongEdges = showLongGraphEdges
    let previousSnapshot = snapshot
    let currentEpoch = epoch
    queue.async { [weak self] in
      do {
        let hash = try repo.resolve(values[0])
        let page = try repo.logPage()
        let commits = page.commits
        func replacingLog(_ old: RepositorySnapshot) -> RepositorySnapshot {
          RepositorySnapshot(branches: old.branches, commits: commits, changes: old.changes,
            currentBranch: old.currentBranch, remotes: old.remotes, stashes: old.stashes,
            operation: old.operation, history: old.history, graphAncestry: old.graphAncestry,
            hasMoreCommits: page.hasMore)
        }
        let presentation = previousSnapshot.map { RepositoryHistoryPresentation.prepare(replacingLog($0), showLongEdges: showLongEdges) }
        DispatchQueue.main.async {
          guard let self, self.epoch == currentEpoch else { return }
          if let index = commits.firstIndex(where: { $0.hash == hash }) {
            self.invalidateHistoryPage()
            self.filter = LogFilter()
            self.loadedLogFilter = self.filter
            self.logSearch.stringValue = ""
            if let old = self.snapshot {
              self.snapshot = replacingLog(old)
              // If another refresh applied while resolving, retain its newer
              // state and prepare synchronously rather than apply stale data.
              self.updateUI(presentation: old == previousSnapshot ? presentation : nil)
            } else {
              self.updateUI()
            }
            self.setMode("Log")
            self.logTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            self.logTable.scrollRowToVisible(index)
          } else {
            self.showError(
              GitFailure("Revision is beyond the current history limit. Load more history first."))
          }
        }
      } catch { DispatchQueue.main.async { self?.showError(error) } }
    }
  }
  func initializeRepository() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Initialize Git"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    standalone("Initialize repository", url: url) {
      try GitRepository(directory: url).run(["init", "-b", "main"])
    }
  }
  func cloneRepository() {
    guard
      let values = prompt(
        "Clone Repository",
        fields: [
          ("Repository URL", ""),
          (
            "Destination directory",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Repositories/")
              .path
          ),
        ]), !values[0].isEmpty, !values[1].isEmpty
    else { return }
    let url = URL(fileURLWithPath: values[1])
    standalone("Clone repository", url: url) {
      let parent = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      try GitRepository(directory: parent).run(["clone", "--", values[0], url.path])
    }
  }
  func standalone(_ title: String, url: URL, work: @escaping () throws -> Void) {
    guard !isBusy else { return }
    isBusy = true
    progress.startAnimation(nil)
    statusLabel.stringValue = title + "…"
    queue.async { [weak self] in
      do {
        try work()
        DispatchQueue.main.async {
          self?.isBusy = false
          self?.progress.stopAnimation(nil)
          self?.open(url)
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
}
