import Foundation

public enum HostingProvider: String, CaseIterable {
  case github, gitlab
  public var title: String { self == .github ? "GitHub" : "GitLab" }
  public var requestTitle: String { self == .github ? "Pull Requests" : "Merge Requests" }
}
public struct HostingRepository: Equatable {
  public let provider: HostingProvider
  public let server: URL
  public let project: String
  public let remote: String
  public var credentialKey: String { provider.rawValue + ":" + server.absoluteString }
  public var webURL: URL { server.appendingPathComponent(project) }
  public var apiBase: String {
    if provider == .github && server.host == "github.com" { return "https://api.github.com" }
    return server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (provider == .github ? "/api/v3" : "/api/v4")
  }
  public var projectAPI: String {
    provider == .github ? "/repos/" + project.split(separator: "/").map { Self.encode(String($0)) }.joined(separator: "/")
      : "/projects/" + Self.encode(project)
  }
  public static func encode(_ string: String) -> String {
    string.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
  }
  public init(remoteURL: String, remote: String, provider: HostingProvider? = nil, server: URL? = nil) throws {
    let value = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsed: URL?
    if !value.contains("://"), let colon = value.firstIndex(of: ":"), value[..<colon].contains("@") {
      parsed = URL(string: "ssh://" + value[..<colon] + "/" + value[value.index(after: colon)...])
    } else { parsed = URL(string: value) }
    guard let parsed, let host = parsed.host, !host.isEmpty,
      ["https", "ssh", "git", "http"].contains(parsed.scheme ?? "") else {
      throw GitFailure("Choose a GitHub or GitLab HTTPS/SSH remote.")
    }
    let kind = provider ?? (host.lowercased().contains("gitlab") ? .gitlab : .github)
    let origin = server ?? URL(string: "https://" + host + (["https", "http"].contains(parsed.scheme ?? "") ? (parsed.port.map { ":\($0)" } ?? "") : ""))!
    guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
      origin.query == nil, origin.fragment == nil else { throw GitFailure("The server URL must use HTTPS without credentials or query parameters.") }
    var path = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let prefix = origin.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !prefix.isEmpty && path.hasPrefix(prefix + "/") { path.removeFirst(prefix.count + 1) }
    if path.hasSuffix(".git") { path.removeLast(4) }
    guard path.split(separator: "/").count >= 2, !path.split(separator: "/").contains("..") else {
      throw GitFailure("The remote must include its owner/group and repository name.")
    }
    self.provider = kind; self.server = origin; self.project = path; self.remote = remote
  }
}
public struct HostedRequest: Equatable {
  public let number: Int
  public let title: String
  public let body: String
  public let author: String
  public let url: URL
  public let state: String
  public let draft: Bool
  public let source: String
  public let target: String
  public let headSHA: String
  public let baseSHA: String
  public let mergeStatus: String
  public let nodeID: String
  public let startSHA: String
  public init(json: [String: Any], provider: HostingProvider) throws {
    guard let number = json[provider == .github ? "number" : "iid"] as? Int,
      let title = json["title"] as? String,
      let urlString = json[provider == .github ? "html_url" : "web_url"] as? String,
      let url = URL(string: urlString), ["https", "http"].contains(url.scheme ?? "") else {
      throw GitFailure("The server returned an invalid review request.")
    }
    let head = json["head"] as? [String: Any] ?? [:], base = json["base"] as? [String: Any] ?? [:]
    let diffs = json["diff_refs"] as? [String: Any] ?? [:]
    self.number = number; self.title = title; self.url = url
    body = json[provider == .github ? "body" : "description"] as? String ?? ""
    let user = json[provider == .github ? "user" : "author"] as? [String: Any] ?? [:]
    author = user[provider == .github ? "login" : "username"] as? String ?? ""
    state = (json["merged_at"] is String) ? "merged" : json["state"] as? String ?? "open"
    draft = json["draft"] as? Bool ?? json["work_in_progress"] as? Bool ?? false
    source = head["ref"] as? String ?? json["source_branch"] as? String ?? ""
    target = base["ref"] as? String ?? json["target_branch"] as? String ?? ""
    headSHA = head["sha"] as? String ?? json["sha"] as? String ?? diffs["head_sha"] as? String ?? ""
    baseSHA = diffs["base_sha"] as? String ?? base["sha"] as? String ?? ""
    nodeID = json["node_id"] as? String ?? ""
    startSHA = diffs["start_sha"] as? String ?? baseSHA
    mergeStatus = json[provider == .github ? "mergeable_state" : "detailed_merge_status"] as? String ?? ""
  }
}
public struct HostedFile {
  public let path: String
  public let oldPath: String
  public let patch: String
  public let status: String
}
public struct HostedComment {
  public let id: Int
  public let author: String
  public let body: String
}
public struct HostedThread {
  public let id: String
  public let firstCommentID: Int
  public let summary: String
  public let body: String
  public let resolved: Bool
  public let canResolve: Bool
}
private final class HostingRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    // Never forward an account's token to a redirect destination.
    completionHandler(nil)
  }
}
public final class HostingClient {
  public let repository: HostingRepository
  private let token: String
  private let session: URLSession
  public init(repository: HostingRepository, token: String, session: URLSession? = nil) {
    self.repository = repository; self.token = token
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    self.session = session ?? URLSession(configuration: configuration, delegate: HostingRedirectPolicy(), delegateQueue: nil)
  }
  deinit { session.finishTasksAndInvalidate() }
  public func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
    let endpoint = path == "/graphql" && repository.provider == .github && repository.server.host != "github.com"
      ? repository.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/graphql" : repository.apiBase + path
    guard let url = URL(string: endpoint) else { throw GitFailure("Invalid API endpoint.") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("GitDesk", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !token.isEmpty {
      request.setValue(repository.provider == .github ? "Bearer " + token : token,
        forHTTPHeaderField: repository.provider == .github ? "Authorization" : "PRIVATE-TOKEN")
    }
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw GitFailure("The server did not return an HTTP response.") }
    guard (200..<300).contains(http.statusCode) else {
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      var message = object?["message"].map { String(describing: $0) } ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
      if !token.isEmpty { message = message.replacingOccurrences(of: token, with: "[redacted]") }
      throw GitFailure("\(repository.provider.title) HTTP \(http.statusCode): \(message.prefix(1000))")
    }
    guard data.count <= 20_000_000 else { throw GitFailure("The server response is too large to display.") }
    return data
  }
  public func object(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
    let data = try await request(path, method: method, body: body)
    if data.isEmpty { return [:] }
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitFailure("Expected a server object.") }
    return value
  }
  public func array(_ path: String) async throws -> [[String: Any]] {
    guard let value = try JSONSerialization.jsonObject(with: await request(path)) as? [[String: Any]] else { throw GitFailure("Expected a server list.") }
    return value
  }
  public var collection: String { repository.projectAPI + (repository.provider == .github ? "/pulls" : "/merge_requests") }
  public func list(state: String = "open", page: Int = 1) async throws -> [HostedRequest] {
    let state = repository.provider == .gitlab && state == "open" ? "opened" : state
    let sort = repository.provider == .github ? "sort=updated&direction=desc" : "order_by=updated_at&sort=desc"
    return try await array(collection + "?state=\(state)&per_page=50&page=\(page)&" + sort)
      .map { try HostedRequest(json: $0, provider: repository.provider) }
  }
  public func details(_ number: Int) async throws -> HostedRequest {
    try HostedRequest(json: await object(collection + "/\(number)"), provider: repository.provider)
  }
  private func allPages(_ path: String) async throws -> [[String: Any]] {
    var values: [[String: Any]] = []
    for page in 1...100 {
      let items = try await array(path + (path.contains("?") ? "&" : "?") + "per_page=100&page=\(page)")
      values += items
      if items.count < 100 { return values }
    }
    throw GitFailure("This request exceeds 10,000 items. Open it on the server for the complete list.")
  }
  public func files(_ number: Int) async throws -> [HostedFile] {
    let github = repository.provider == .github
    return try await allPages(collection + "/\(number)/" + (github ? "files" : "diffs")).map {
      HostedFile(path: $0[github ? "filename" : "new_path"] as? String ?? "",
        oldPath: $0[github ? "previous_filename" : "old_path"] as? String ?? "",
        patch: $0[github ? "patch" : "diff"] as? String ?? "Binary file, or diff omitted by the server. Fetch and show the local diff to inspect the full contents.",
        status: $0["status"] as? String ?? (($0["new_file"] as? Bool == true) ? "added" : ($0["deleted_file"] as? Bool == true) ? "removed" : "modified"))
    }
  }
  public func comments(_ number: Int) async throws -> [HostedComment] {
    let github = repository.provider == .github
    let path = github ? repository.projectAPI + "/issues/\(number)/comments" : collection + "/\(number)/notes"
    return try await allPages(path).map {
      let user = $0[github ? "user" : "author"] as? [String: Any] ?? [:]
      return HostedComment(id: $0["id"] as? Int ?? 0, author: user[github ? "login" : "username"] as? String ?? "", body: $0["body"] as? String ?? "")
    }
  }
  public func create(title: String, body: String, source: String, target: String, draft: Bool) async throws -> HostedRequest {
    let github = repository.provider == .github
    let json: [String: Any] = github ? ["title": title, "body": body, "head": source, "base": target, "draft": draft]
      : ["title": draft && !title.lowercased().hasPrefix("draft:") ? "Draft: " + title : title, "description": body, "source_branch": source, "target_branch": target]
    return try HostedRequest(json: await object(collection, method: "POST", body: json), provider: repository.provider)
  }
  public func comment(_ number: Int, body: String) async throws {
    let path = repository.provider == .github ? repository.projectAPI + "/issues/\(number)/comments" : collection + "/\(number)/notes"
    _ = try await request(path, method: "POST", body: ["body": body])
  }
  public func review(_ request: HostedRequest, action: String, body: String) async throws {
    if repository.provider == .github {
      _ = try await self.request(collection + "/\(request.number)/reviews", method: "POST", body: ["event": action, "body": body, "commit_id": request.headSHA])
    } else {
      if action == "APPROVE" {
        _ = try await self.request(collection + "/\(request.number)/approve", method: "POST", body: ["sha": request.headSHA])
      } else if action == "UNAPPROVE" {
        _ = try await self.request(collection + "/\(request.number)/unapprove", method: "POST")
      } else { try await comment(request.number, body: body) }
    }
  }
  public func setState(_ number: Int, open: Bool) async throws {
    let github = repository.provider == .github
    _ = try await request(collection + "/\(number)", method: github ? "PATCH" : "PUT",
      body: github ? ["state": open ? "open" : "closed"] : ["state_event": open ? "reopen" : "close"])
  }
  public func merge(_ request: HostedRequest, method: String) async throws {
    let github = repository.provider == .github
    let data = try await self.request(collection + "/\(request.number)/merge", method: "PUT",
      body: github ? ["sha": request.headSHA, "merge_method": method] : ["sha": request.headSHA, "squash": method == "squash"])
    if github, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["merged"] as? Bool == false {
      throw GitFailure(result["message"] as? String ?? "The server did not merge this request.")
    }
  }
  public func edit(_ number: Int, title: String, body: String) async throws {
    let github = repository.provider == .github
    _ = try await request(collection + "/\(number)", method: github ? "PATCH" : "PUT",
      body: github ? ["title": title, "body": body] : ["title": title, "description": body])
  }
  public func setDraft(_ request: HostedRequest, draft: Bool) async throws {
    if repository.provider == .gitlab {
      let title = request.title.replacingOccurrences(of: "^(Draft:|WIP:)\\s*", with: "", options: [.regularExpression, .caseInsensitive])
      try await edit(request.number, title: draft ? "Draft: " + title : title, body: request.body)
    } else {
      guard !request.nodeID.isEmpty else { throw GitFailure("Reload request details before changing its draft state.") }
      let operation = draft ? "convertPullRequestToDraft" : "markPullRequestReadyForReview"
      let result = try await object("/graphql", method: "POST", body: ["query": "mutation($id: ID!) { \(operation)(input: {pullRequestId: $id}) { pullRequest { isDraft } } }", "variables": ["id": request.nodeID]])
      if let errors = result["errors"] { throw GitFailure(String(describing: errors)) }
    }
  }
  public func requestReviewers(_ number: Int, usernames: [String]) async throws {
    if repository.provider == .github {
      _ = try await request(collection + "/\(number)/requested_reviewers", method: "POST", body: ["reviewers": usernames])
    } else {
      var ids: [Int] = []
      for user in usernames {
        let matches = try await array("/users?username=" + HostingRepository.encode(user))
        guard let id = matches.first?["id"] as? Int else { throw GitFailure("No GitLab user named \(user).") }
        ids.append(id)
      }
      _ = try await request(collection + "/\(number)", method: "PUT", body: ["reviewer_ids": ids])
    }
  }
  public func lineComment(_ review: HostedRequest, path: String, oldPath: String, line: Int, left: Bool, body: String) async throws {
    guard line > 0, !body.isEmpty else { throw GitFailure("Choose a source line and enter a comment.") }
    if repository.provider == .github {
      _ = try await request(collection + "/\(review.number)/comments", method: "POST",
        body: ["body": body, "commit_id": review.headSHA, "path": path, "line": line, "side": left ? "LEFT" : "RIGHT"])
    } else {
      let position: [String: Any] = ["position_type": "text", "base_sha": review.baseSHA, "start_sha": review.startSHA,
        "head_sha": review.headSHA, "new_path": path, "old_path": oldPath.isEmpty ? path : oldPath,
        left ? "old_line" : "new_line": line]
      _ = try await request(collection + "/\(review.number)/discussions", method: "POST", body: ["body": body, "position": position])
    }
  }
  public func threads(_ number: Int) async throws -> [HostedThread] {
    if repository.provider == .gitlab {
      return try await allPages(collection + "/\(number)/discussions").compactMap { thread in
        let notes = thread["notes"] as? [[String: Any]] ?? []
        guard let first = notes.first, first["resolvable"] as? Bool == true else { return nil }
        let position = first["position"] as? [String: Any] ?? [:]
        let path = position["new_path"] as? String ?? position["old_path"] as? String ?? "Discussion"
        return HostedThread(id: thread["id"] as? String ?? "", firstCommentID: first["id"] as? Int ?? 0,
          summary: path + ":" + String(describing: position["new_line"] ?? position["old_line"] ?? ""),
          body: notes.map { "\(($0["author"] as? [String: Any])?["username"] ?? "")\n\($0["body"] ?? "")" }.joined(separator: "\n\n"),
          resolved: first["resolved"] as? Bool ?? false, canResolve: true)
      }
    }
    let pieces = repository.project.split(separator: "/")
    guard pieces.count == 2 else { throw GitFailure("GitHub repositories require owner/repository.") }
    var cursor: String?, threads: [HostedThread] = []
    for _ in 0..<100 {
      let query = "query($owner: String!, $name: String!, $number: Int!, $cursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id path line originalLine isResolved viewerCanResolve viewerCanUnresolve comments(first: 100) { nodes { databaseId body author { login } } } } } } } }"
      var variables: [String: Any] = ["owner": String(pieces[0]), "name": String(pieces[1]), "number": number]
      if let cursor { variables["cursor"] = cursor }
      let result = try await object("/graphql", method: "POST", body: ["query": query, "variables": variables])
      if let errors = result["errors"] { throw GitFailure(String(describing: errors)) }
      let data = result["data"] as? [String: Any] ?? [:], repo = data["repository"] as? [String: Any] ?? [:]
      let pull = repo["pullRequest"] as? [String: Any] ?? [:], connection = pull["reviewThreads"] as? [String: Any] ?? [:]
      for thread in connection["nodes"] as? [[String: Any]] ?? [] {
        let comments = (thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let resolved = thread["isResolved"] as? Bool ?? false
        threads.append(HostedThread(id: thread["id"] as? String ?? "", firstCommentID: comments.first?["databaseId"] as? Int ?? 0,
          summary: "\(thread["path"] ?? "Discussion"):\(thread["line"] ?? thread["originalLine"] ?? "")",
          body: comments.map { "\(($0["author"] as? [String: Any])?["login"] ?? "")\n\($0["body"] ?? "")" }.joined(separator: "\n\n"),
          resolved: resolved, canResolve: thread[resolved ? "viewerCanUnresolve" : "viewerCanResolve"] as? Bool ?? false))
      }
      let info = connection["pageInfo"] as? [String: Any] ?? [:]
      if info["hasNextPage"] as? Bool != true { return threads }
      cursor = info["endCursor"] as? String
    }
    throw GitFailure("Too many review threads. Open this request on the server.")
  }
  public func reply(_ number: Int, thread: HostedThread, body: String) async throws {
    let path = repository.provider == .github ? collection + "/\(number)/comments/\(thread.firstCommentID)/replies"
      : collection + "/\(number)/discussions/" + HostingRepository.encode(thread.id) + "/notes"
    _ = try await request(path, method: "POST", body: ["body": body])
  }
  public func resolve(_ number: Int, thread: HostedThread) async throws {
    if repository.provider == .gitlab {
      _ = try await request(collection + "/\(number)/discussions/" + HostingRepository.encode(thread.id), method: "PUT", body: ["resolved": !thread.resolved])
    } else {
      let operation = thread.resolved ? "unresolveReviewThread" : "resolveReviewThread"
      let result = try await object("/graphql", method: "POST", body: ["query": "mutation($id: ID!) { \(operation)(input: {threadId: $id}) { thread { isResolved } } }", "variables": ["id": thread.id]])
      if let errors = result["errors"] { throw GitFailure(String(describing: errors)) }
    }
  }
  public func createSnippet(title: String, files: [String: String], isPublic: Bool) async throws -> URL {
    let github = repository.provider == .github
    let body: [String: Any] = github ? ["description": title, "public": isPublic, "files": files.mapValues { ["content": $0] }]
      : ["title": title, "visibility": isPublic ? "public" : "private", "files": files.map { ["file_path": $0.key, "content": $0.value] }]
    let result = try await object(github ? "/gists" : repository.projectAPI + "/snippets", method: "POST", body: body)
    guard let value = result[github ? "html_url" : "web_url"] as? String, let url = URL(string: value), url.scheme == "https" else { throw GitFailure("The server did not return a snippet URL.") }
    return url
  }
  public func status(_ request: HostedRequest) async throws -> String {
    if repository.provider == .github {
      let results = try await object(repository.projectAPI + "/commits/\(HostingRepository.encode(request.headSHA))/status")
      let checks = try await object(repository.projectAPI + "/commits/\(HostingRepository.encode(request.headSHA))/check-runs")
      let statuses = (results["statuses"] as? [[String: Any]] ?? []).map { "\($0["context"] ?? "Status"): \($0["state"] ?? "unknown")" }
      let runs = (checks["check_runs"] as? [[String: Any]] ?? []).map { "\($0["name"] ?? "Check"): \($0["conclusion"] ?? $0["status"] ?? "unknown")" }
      return (statuses + runs).joined(separator: "\n")
    }
    return try await array(collection + "/\(request.number)/pipelines").map { "Pipeline #\($0["id"] ?? ""): \($0["status"] ?? "unknown")" }.joined(separator: "\n")
  }
  public func reviews(_ number: Int) async throws -> String {
    let github = repository.provider == .github
    if github {
      return try await allPages(collection + "/\(number)/reviews").map {
        let user = $0["user"] as? [String: Any] ?? [:]
        return "\(user["login"] ?? ""): \($0["state"] ?? "")\n\($0["body"] ?? "")"
      }.joined(separator: "\n\n")
    }
    let approvals = try await object(collection + "/\(number)/approvals")
    return "Approvals: \(approvals["approvals_left"] ?? "unknown") remaining\n" +
      (approvals["approved_by"] as? [[String: Any]] ?? []).map { (($0["user"] as? [String: Any])?["username"] as? String ?? "") + " approved" }.joined(separator: "\n")
  }
}
