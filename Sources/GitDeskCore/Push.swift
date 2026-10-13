import Foundation

public struct PushTarget: Equatable {
  public let remote: String
  public let destination: String
  public var branch: String {
    destination.hasPrefix("refs/heads/") ? String(destination.dropFirst("refs/heads/".count)) : destination
  }
}

extension GitRepository {
  private func pushConfig(_ key: String) throws -> String? {
    let value = try run(["config", "--get", key], allowFailure: true)
      .trimmingCharacters(in: .newlines)
    return value.isEmpty ? nil : value
  }
  public func defaultPushTarget() throws -> PushTarget {
    let branch = try run(["symbolic-ref", "--quiet", "--short", "HEAD"])
      .trimmingCharacters(in: .newlines)
    let remotes = try run(["remote"]).split(separator: "\n").map(String.init)
    guard let fallback = remotes.first(where: { $0 == "origin" }) ?? remotes.first else {
      throw GitFailure("Configure a remote before pushing.")
    }
    let trackingRemote = try pushConfig("branch.\(branch).remote")
    let trackingRef = try pushConfig("branch.\(branch).merge")
    let remote = trackingRemote.flatMap { remotes.contains($0) ? $0 : nil } ?? fallback
    // IDEA prefers a matching push refspec, then the upstream, then a same-name branch.
    let specs = try run(["config", "--get-all", "remote.\(remote).push"], allowFailure: true)
      .split(separator: "\n").map(String.init)
    var wildcardTarget: PushTarget?
    func target(_ destination: String) -> PushTarget {
      let remotePrefix = "refs/remotes/" + remote + "/"
      let ref = destination.hasPrefix(remotePrefix)
        ? "refs/heads/" + destination.dropFirst(remotePrefix.count) : canonicalPushRef(destination)
      return PushTarget(remote: remote, destination: ref)
    }
    for spec in specs {
      let fields = spec.split(separator: ":", omittingEmptySubsequences: false)
      guard fields.count == 2 else { continue }
      let source = String(fields[0]).trimmingCharacters(in: .whitespaces).drop(while: { $0 == "+" })
      let destination = String(fields[1]).trimmingCharacters(in: .whitespaces)
      guard !destination.isEmpty else { continue }
      if !source.contains("*"), !destination.contains("*"),
        source == branch || source == "refs/heads/" + branch || source == "HEAD" {
        return target(destination)
      }
      // Match IDEA's first trailing-wildcard rule; exact specs take precedence.
      if wildcardTarget == nil, source.last == "*", destination.last == "*",
        source.filter({ $0 == "*" }).count == 1, destination.filter({ $0 == "*" }).count == 1 {
        let prefix = String(source.dropLast())
        let fullBranch = "refs/heads/" + branch
        if fullBranch.hasPrefix(prefix) {
          wildcardTarget = target(String(destination.dropLast()) + fullBranch.dropFirst(prefix.count))
        }
      }
    }
    if let wildcardTarget { return wildcardTarget }
    if trackingRemote == remote, let trackingRef {
      return PushTarget(remote: remote, destination: trackingRef)
    }
    return PushTarget(remote: fallback, destination: "refs/heads/" + branch)
  }
  private func canonicalPushRef(_ destination: String) -> String {
    destination.hasPrefix("refs/") ? destination : "refs/heads/" + destination
  }
  public func push(remote: String, branch destination: String) throws {
    let branch = try run(["symbolic-ref", "--quiet", "--short", "HEAD"])
      .trimmingCharacters(in: .newlines)
    let remotes = try run(["remote"]).split(separator: "\n").map(String.init)
    guard remotes.contains(remote) else { throw GitFailure("The selected remote no longer exists.") }
    let ref = canonicalPushRef(destination)
    try run(["check-ref-format", ref])
    let hasTracking = try pushConfig("branch.\(branch).remote") != nil
      && pushConfig("branch.\(branch).merge") != nil
    let existing = try run(["show-ref", "--verify", "refs/remotes/\(remote)/" + String(ref.dropFirst("refs/heads/".count))], allowFailure: true)
    // Like IDEA, establish tracking only for a new branch without existing tracking.
    let setUpstream = !hasTracking && ref.hasPrefix("refs/heads/") && existing.isEmpty
    try run(["push"] + (setUpstream ? ["--set-upstream"] : []) + ["--", remote, "HEAD:" + ref])
  }
}
