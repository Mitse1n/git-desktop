// Compiled with the real Release core and AppKit sources by bench.py.
import AppKit
import GitDeskCore
import Darwin

let argv = CommandLine.arguments
guard argv.count >= 4 else { fatalError("probe repository iterations mode(core|ui|diff)") }
let root = URL(fileURLWithPath: argv[1])
let iterations = Int(argv[2])!
let mode = argv[3]
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func memory() -> [String: Double] {
  var basic = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: basic) / MemoryLayout<integer_t>.size)
  let status = withUnsafeMutablePointer(to: &basic) { p in
    p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  var vm = task_vm_info_data_t()
  var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
  let vmStatus = withUnsafeMutablePointer(to: &vm) { p in
    p.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
    }
  }
  return ["rss_mib": status == KERN_SUCCESS ? Double(basic.resident_size) / 1048576 : -1,
    "footprint_mib": vmStatus == KERN_SUCCESS ? Double(vm.phys_footprint) / 1048576 : -1,
    "process_peak_footprint_mib": vmStatus == KERN_SUCCESS ? Double(vm.ledger_phys_footprint_peak) / 1048576 : -1,
    "process_peak_rss_mib": Double(usage.ru_maxrss) / 1048576]
}
func emit(_ value: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self)); fflush(stdout)
}
func measure(_ name: String, _ body: () throws -> [String: Any]) rethrows {
  for i in 0...iterations {
    try autoreleasepool {
      let start = now()
      let detail = try body()
      var result: [String: Any] = ["metric": name, "iteration": i, "warmup": i == 0,
        "ms": (now() - start) * 1000, "memory": memory(), "detail": detail]
      result["mode"] = mode
      emit(result)
    }
  }
}
func pump(until ready: () -> Bool, timeout: Double = 120) {
  let deadline = now() + timeout
  while !ready() && now() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
  }
  precondition(ready(), "Timed out waiting for real controller")
}
func sizeView(_ view: NSView, in window: NSWindow) {
  NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 1440),
    view.heightAnchor.constraint(equalToConstant: 850)])
  window.setContentSize(NSSize(width: 1440, height: 850))
  view.setFrameSize(NSSize(width: 1440, height: 850))
  view.layoutSubtreeIfNeeded()
  precondition(abs(view.bounds.width - 1440) < 0.5 && abs(view.bounds.height - 850) < 0.5)
}
do {
  if mode == "diff" {
    let scenario = root.lastPathComponent
    let lines = scenario.contains("10000") ? 10000 : scenario.contains("5000") ? 5000 : 1000
    let before = Data((0..<lines).map { "original line \($0) value = \($0)\n" }.joined().utf8)
    let after: Data
    if scenario.contains("binary") { after = Data([0, 1, 2, 3]) }
    else if scenario.contains("bytes-limit") { after = Data(repeating: 65, count: 2_000_001) }
    else if scenario.contains("lines-limit") { after = Data(String(repeating: "x\n", count: 20001).utf8) }
    else if scenario.contains("replace") {
      after = Data((0..<lines).map { "replacement \($0) completely different\n" }.joined().utf8)
    } else if scenario.contains("whitespace") {
      after = Data(String(decoding: before, as: UTF8.self).replacingOccurrences(of: " = ", with: "    = ").utf8)
    } else {
      after = Data(String(decoding: before, as: UTF8.self).replacingOccurrences(of: "line 500 ", with: "line CHANGED ").utf8)
    }
    measure(scenario) {
      let diff = TextDiff(before: before, after: after, ignoreWhitespace: scenario.contains("whitespace"))
      if scenario.hasPrefix("sparse") { precondition(diff.changes.count == 1) }
      if scenario.contains("whitespace") { precondition(diff.changes.isEmpty && !diff.identical) }
      if scenario.contains("replace") { precondition(diff.rows.count == lines && diff.changes.count == 1) }
      if scenario == "binary" { precondition(diff.binary) }
      if scenario == "bytes-limit" { precondition(diff.tooLarge) }
      if scenario == "lines-limit" { precondition(diff.rows.isEmpty) }
      return ["rows": diff.rows.count, "changes": diff.changes.count, "binary": diff.binary,
        "tooLarge": diff.tooLarge, "before_bytes": before.count, "after_bytes": after.count]
    }
  } else {
    let repo = try GitRepository(url: root)
    if mode == "core" {
      try measure("snapshot") {
        let snapshot = try repo.snapshot()
        return ["commits": snapshot.commits.count, "ancestry": snapshot.graphAncestry.count,
          "changes": snapshot.changes.count, "refs": snapshot.branches.count]
      }
      let snapshot = try repo.snapshot()
      measure("graph") {
        let graph = CommitGraph.layout(snapshot.commits, topology: snapshot.graphAncestry,
          heads: snapshot.branches.map(\.hash))
        return ["rows": graph.count, "lanes": CommitGraph.recommendedLaneCount(graph)]
      }
      try measure("status") { ["files": try repo.status().count] }
      var filter = LogFilter(); filter.text = "needle"
      try measure("filter_text") { ["matches": try repo.filteredSnapshot(from: snapshot, filter: filter).commits.count] }
      filter.regex = true; filter.text = "needle|commit [0-9]*7$"
      try measure("filter_regex") { ["matches": try repo.filteredSnapshot(from: snapshot, filter: filter).commits.count] }
      filter = LogFilter(); filter.limit = 10000
      try measure("log_10000") { ["commits": try repo.log(filter).count] }
      if let commit = snapshot.commits.first {
        try measure("commit_details") { ["files": try repo.changes(in: commit).count] }
      }
    } else {
      _ = NSApplication.shared
      NSApp.setActivationPolicy(.prohibited)
      let controller = RepositoryController()
      let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1440, height: 850),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = controller
      _ = controller.view
      sizeView(controller.view, in: window)
      controller.watcher?.invalidate() // Isolate explicit actions from the five-second poll.
      emit(["metric": "ui_baseline", "memory": memory()])
      measure("ui_open") {
        controller.open(root)
        pump(until: { !controller.isBusy })
        precondition(controller.repository != nil && controller.snapshot != nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return ["commits": controller.snapshot!.commits.count,
          "viewport_width": controller.view.bounds.width, "viewport_height": controller.view.bounds.height]
      }
      measure("ui_refresh") {
        controller.refresh()
        pump(until: { !controller.isRefreshing && !controller.pendingRefresh })
        return [:]
      }
      // Only generated fixtures are mutated; each change is restored before exit.
      if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/gitdesk-benchmark.json").path) {
        let marker = root.appendingPathComponent(".gitdesk-perf-toggle")
        precondition(!FileManager.default.fileExists(atPath: marker.path))
        measure("ui_worktree_change_refresh") {
          if FileManager.default.fileExists(atPath: marker.path) { try! FileManager.default.removeItem(at: marker) }
          else { try! Data("benchmark\n".utf8).write(to: marker) }
          controller.refresh()
          pump(until: { !controller.isRefreshing && !controller.pendingRefresh })
          return ["changes": controller.snapshot!.changes.count]
        }
        try? FileManager.default.removeItem(at: marker)
        controller.refresh(); pump(until: { !controller.isRefreshing })
      }
      measure("ui_rebuild_main_thread") {
        controller.updateUI()
        window.contentView?.layoutSubtreeIfNeeded()
        return [:]
      }
      measure("ui_search_with_debounce") {
        controller.filter.text = controller.filter.text.isEmpty ? "needle" : ""
        let start = now()
        // Match the actual 250 ms input debounce before issuing a log-only refresh.
        while now() - start < 0.25 { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
        controller.refresh(logOnly: true)
        pump(until: { !controller.isRefreshing && !controller.pendingRefresh })
        return ["matches": controller.snapshot!.commits.count]
      }
      controller.filter.text = ""; controller.refresh(logOnly: true)
      pump(until: { !controller.isRefreshing })
      if let commit = controller.snapshot?.commits.first {
        measure("ui_commit_details") {
          controller.loadedDetailHash = nil
          controller.loadDetails(commit)
          pump(until: { controller.loadedDetailHash == commit.hash })
          return ["files": controller.detailFiles.count]
        }
      }
      let viewer = DiffViewController()
      let diffWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1440, height: 850),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      diffWindow.isReleasedWhenClosed = false
      diffWindow.contentViewController = viewer
      _ = viewer.view
      sizeView(viewer.view, in: diffWindow)
      let diffPath = FileManager.default.fileExists(atPath: root.appendingPathComponent("diff.txt").path) ? "diff.txt" : "sample.txt"
      let change = FileChange(path: diffPath, index: " ", worktree: "M")
      if FileManager.default.fileExists(atPath: root.appendingPathComponent(diffPath).path) {
        measure("ui_working_diff") {
          viewer.load(repository: repo, change: change)
          pump(until: { viewer.diff != nil })
          return ["rows": viewer.diff!.rows.count]
        }
        func drainDiff() {
          // I/O can enqueue calculation via the main queue, requiring two barriers.
          for _ in 0..<2 {
            var done = false
            viewer.queue.async { DispatchQueue.main.async { done = true } }
            pump(until: { done })
          }
        }
        measure("ui_diff_layout_switch") {
          viewer.layoutToggle.selectedSegment = 1 - viewer.layoutToggle.selectedSegment
          viewer.optionsChanged(); drainDiff()
          return ["rows": viewer.diff!.rows.count]
        }
        measure("ui_diff_options_burst") {
          // Keep the worker occupied until five replacement requests have queued.
          let gate = DispatchSemaphore(value: 0)
          viewer.queue.async { gate.wait() }
          for _ in 0..<5 {
            viewer.whitespace.state = viewer.whitespace.state == .on ? .off : .on
            viewer.optionsChanged()
          }
          gate.signal(); drainDiff()
          return ["rows": viewer.diff!.rows.count]
        }
      }
      emit(["metric": "ui_final", "memory": memory(), "console_utf16": controller.consoleText.string.utf16.count])
      window.close()
      diffWindow.close()
    }
  }
} catch { fputs("\(error)\n", stderr); exit(1) }
