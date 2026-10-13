import AppKit
import GitDeskCore

extension RepositoryController {
  func invalidateHistoryPage() {
    historyPageToken += 1
    isLoadingMoreHistory = false
  }
  func loadMoreHistory() {
    guard let repo = repository, let previous = snapshot, previous.hasMoreCommits,
      let loaded = loadedLogFilter, loaded == filter, historyPageSize > 0,
      loaded.limit <= Int.max - historyPageSize - 1,
      !isBusy, !isRefreshing, !isLoadingMoreHistory, !rebuildingLog, debounce == nil else { return }
    isLoadingMoreHistory = true
    historyPageToken += 1
    let pageToken = historyPageToken, currentEpoch = epoch, refreshToken = loadToken
    var expanded = loaded
    expanded.limit += historyPageSize
    let showLongEdges = showLongGraphEdges
    let priorPresentation = historyPresentation
    statusLabel.stringValue = "Loading older commits…"
    queue.async { [weak self] in
      let result = Result {
        // Re-read a coherent prefix instead of concatenating offsets from moving
        // refs. New external commits cannot produce duplicate or missing rows.
        let data = try repo.snapshot(filter: expanded)
        return (data, RepositoryHistoryPresentation.prepare(data, reusing: priorPresentation, showLongEdges: showLongEdges))
      }
      DispatchQueue.main.async {
        guard let self, self.epoch == currentEpoch, self.historyPageToken == pageToken else { return }
        self.isLoadingMoreHistory = false
        guard self.loadToken == refreshToken, self.filter == loaded, !self.isBusy else { return }
        switch result {
        case .success(let (data, presentation)):
          let visible = self.logTable.rows(in: self.logTable.visibleRect)
          let anchorRow = visible.location
          let anchor = self.displayedLogCommits.indices.contains(anchorRow)
            ? self.displayedLogCommits[anchorRow].hash : nil
          let offset = anchor == nil ? 0 : self.logTable.visibleRect.minY - self.logTable.rect(ofRow: anchorRow).minY
          self.filter = expanded
          self.loadedLogFilter = expanded
          self.snapshot = data
          self.updateUI(previous: previous, presentation: presentation)
          // Selection is restored by hash by updateUI; restore the viewport by
          // hash too, even if HEAD advanced while the query was running.
          if let anchor, let row = data.commits.firstIndex(where: { $0.hash == anchor }),
            let scroll = self.logTable.enclosingScrollView {
            var point = scroll.contentView.bounds.origin
            point.y = self.logTable.rect(ofRow: row).minY + offset
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
          }
          self.updateStatus()
        case .failure(let error):
          // Keep the prior page and limit intact so another scroll can retry.
          self.statusLabel.stringValue = "Could not load older commits: " + error.localizedDescription
        }
      }
    }
  }
}
