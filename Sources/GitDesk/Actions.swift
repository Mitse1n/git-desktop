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
          self?.perform("Abort \(operation)", work: { try $0.run([operation, "--abort"]) })
        })
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
    let menu = NSMenu()
    menu.addItem(
      menuItem("New Branch…", enabled: repository != nil) { [weak self] in self?.newBranch() })
    menu.addItem(
      menuItem("Checkout Tag or Revision…", enabled: repository != nil) { [weak self] in
        self?.checkoutRevision()
      })
    menu.addItem(.separator())
    for branch in snapshot?.branches ?? [] {
      let item = NSMenuItem(
        title: branch.name + (branch.current ? "  (Current)" : ""), action: nil, keyEquivalent: "")
      item.submenu = branchMenu(branch)
      menu.addItem(item)
    }
    popup(menu, anchor: branchLabel)
  }
  func branchContextMenu() -> NSMenu {
    if let branch = selectedBranch { return branchMenu(branch) }
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
        [weak self] in
        guard let self else { return }
        var refs = self.favoriteRefs
        if refs.contains(branch.fullRef) {
          refs.remove(branch.fullRef)
        } else {
          refs.insert(branch.fullRef)
        }
        self.favoriteRefs = refs
        self.rebuildBranches()
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
  func deleteBranch(_ branch: Branch? = nil) {
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
          self.detailTitle.stringValue = "Comparison"
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
    menu.addItem(.separator())
    menu.addItem(menuItem("Show Diff") { [weak self] in self?.showDiff() })
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
    menu.addItem(
      menuItem("Show Diff") { [weak self] in working ? self?.showWorkingDiff() : self?.showDiff() })
    if working {
      menu.addItem(
        menuItem("Stage") { [weak self] in
          guard let self else { return }
          let files = self.workingSelection()
          if !files.isEmpty { self.perform("Stage files", work: { try $0.stage(files) }) }
        })
      menu.addItem(
        menuItem("Unstage") { [weak self] in
          guard let self else { return }
          let files = self.workingSelection()
          if !files.isEmpty { self.perform("Unstage files", work: { try $0.unstage(files) }) }
        })
      menu.addItem(menuItem("Rollback…") { [weak self] in self?.rollback() })
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
      menuItem("Copy Path") { [weak self] in
        guard let self else { return }
        let files = working ? self.workingSelection() : self.selectedDetailFiles
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
      })
    menu.addItem(
      menuItem("Show in Finder") { [weak self] in
        guard let self, let repo = self.repository else { return }
        let files = working ? self.workingSelection() : self.selectedDetailFiles
        NSWorkspace.shared.activateFileViewerSelecting(
          files.map { repo.workingDirectory.appendingPathComponent($0.path) })
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
    guard amend.state == .on else { return }
    let old = snapshot?.commits.first(where: {
      $0.decorations.contains(where: { $0.hasPrefix("HEAD") })
    })
    if commitMessage.string.isEmpty, let old {
      commitMessage.string = old.subject + (old.body.isEmpty ? "" : "\n\n" + old.body)
    }
  }
  func commitChanges(push shouldPush: Bool) {
    let files = snapshot?.changes.filter { selectedPaths.contains($0.path) } ?? []
    let message = commitMessage.string
    let isAmend = amend.state == .on
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
      work: { try $0.commit(message: message, changes: files, amend: isAmend) },
      completion: { [weak self] in
        guard let self else { return }
        var history = UserDefaults.standard.stringArray(forKey: "commitMessages") ?? []
        history.removeAll { $0 == message }
        history.insert(message, at: 0)
        UserDefaults.standard.set(Array(history.prefix(20)), forKey: "commitMessages")
        self.commitMessage.string = ""
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
      let branch = data.branches.first(where: \.current)
    else {
      statusLabel.stringValue = "Configure a remote and checkout a branch before pushing."
      return
    }
    let remote = NSPopUpButton()
    remote.addItems(withTitles: data.remotes)
    guard
      let values = prompt("Push Commits", fields: [("Remote branch", branch.name)], extra: remote),
      !values[0].isEmpty
    else { return }
    let remoteName = remote.titleOfSelectedItem ?? data.remotes[0]
    perform(
      "Push",
      work: { try $0.run(["push", "--set-upstream", remoteName, "HEAD:refs/heads/" + values[0]]) })
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
      work: { try $0.run(["-c", "core.editor=true", operation, "--continue"]) })
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
        try $0.run(["checkout", "--" + side, "--"] + files.map(\.path))
        try $0.stage(files)
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
  func detailsOptions() {
    let menu = NSMenu()
    menu.addItem(
      menuItem("Copy Commit Details") { [weak self] in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(self?.detailsText.string ?? "", forType: .string)
      })
    popup(menu)
  }
  func filterMenu() {
    let menu = NSMenu()
    let compact = menuItem("Compact Reference Names") { [weak self] in
      self?.compactReferences.toggle()
      self?.logTable.reloadData()
    }
    compact.state = compactReferences ? .on : .off
    menu.addItem(compact)
    let highlight = menuItem("Highlight Current Branch") { [weak self] in
      self?.highlightCurrentBranch.toggle()
      self?.logTable.reloadData()
    }
    highlight.state = highlightCurrentBranch ? .on : .off
    menu.addItem(highlight)
    menu.addItem(.separator())
    menu.addItem(
      menuItem("Filter by Path…") { [weak self] in
        guard let self,
          let values = self.prompt(
            "Paths Filter", fields: [("Repository-relative path", self.filter.path ?? "")])
        else { return }
        self.filter.path = values[0].isEmpty ? nil : values[0]
        self.refresh(logOnly: true)
      })
    let first = menuItem("First Parent Only") { [weak self] in
      self?.filter.firstParent.toggle()
      self?.refresh(logOnly: true)
    }
    first.state = filter.firstParent ? .on : .off
    menu.addItem(first)
    menu.addItem(
      menuItem("Clear All Filters") { [weak self] in
        guard let self else { return }
        self.filter = LogFilter()
        self.logSearch.stringValue = ""
        self.datePopup.selectItem(at: 0)
        self.regexButton.contentTintColor = Theme.text
        self.caseButton.contentTintColor = Theme.text
        self.refresh(logOnly: true)
      })
    menu.addItem(.separator())
    let group = menuItem("Group Branches by Prefix") { [weak self] in
      self?.groupBranches.toggle()
      self?.rebuildBranches()
    }
    group.state = groupBranches ? .on : .off
    menu.addItem(group)
    let tags = menuItem("Show Tags") { [weak self] in
      self?.showTags.toggle()
      self?.rebuildBranches()
    }
    tags.state = showTags ? .on : .off
    menu.addItem(tags)
    menu.addItem(
      menuItem(branchHidden ? "Show Git Branches" : "Hide Git Branches") { [weak self] in
        self?.toggleBranches()
      })
    menu.addItem(
      menuItem("Load More History (10,000)") { [weak self] in
        self?.filter.limit = 10000
        self?.refresh()
      })
    popup(menu)
  }
  func focusSearch() {
    setMode("Log")
    view.window?.makeFirstResponder(logSearch)
  }
  func goTo() {
    guard let values = prompt("Go to Hash / Branch / Tag", fields: [("Revision", "")]),
      !values[0].isEmpty, let repo = repository
    else { return }
    queue.async { [weak self] in
      do {
        let hash = try repo.resolve(values[0])
        let commits = try repo.log()
        DispatchQueue.main.async {
          guard let self else { return }
          if let index = commits.firstIndex(where: { $0.hash == hash }) {
            self.filter = LogFilter()
            self.logSearch.stringValue = ""
            if let old = self.snapshot {
              self.snapshot = RepositorySnapshot(
                branches: old.branches, commits: commits, changes: old.changes,
                currentBranch: old.currentBranch, remotes: old.remotes, stashes: old.stashes,
                operation: old.operation)
            }
            self.updateUI()
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
