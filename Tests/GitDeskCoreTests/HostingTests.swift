import Foundation
import GitDeskCore

private final class HostingFixtureProtocol: URLProtocol {
  static let lock = NSLock()
  static var handler: ((URLRequest) throws -> (Int, Any))?
  static func install(_ value: @escaping (URLRequest) throws -> (Int, Any)) { lock.lock(); handler = value; lock.unlock() }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
      let (code, payload) = try handler!(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: payload))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
extension GitRepositoryTests {
  func testHostingAPIContracts() throws {
    let github = try HostingRepository(remoteURL: "git@github.com:owner/repo.git", remote: "origin")
    XCTAssertEqual(github.project, "owner/repo")
    XCTAssertEqual(github.apiBase, "https://api.github.com")
    let gitlab = try HostingRepository(remoteURL: "ssh://git@gitlab.example:2222/group/subgroup/repo.git", remote: "upstream", provider: .gitlab)
    XCTAssertEqual(gitlab.apiBase, "https://gitlab.example/api/v4")
    XCTAssertEqual(gitlab.projectAPI, "/projects/group%2Fsubgroup%2Frepo")
    let prefixed = try HostingRepository(remoteURL: "https://example.test/gitlab/team/project.git", remote: "origin", provider: .gitlab, server: URL(string: "https://example.test/gitlab")!)
    XCTAssertEqual(prefixed.project, "team/project")
    XCTAssertEqual(prefixed.apiBase, "https://example.test/gitlab/api/v4")
    XCTAssertThrowsError(try HostingRepository(remoteURL: "file:///tmp/repo", remote: "origin"))
    XCTAssertThrowsError(try HostingRepository(remoteURL: "https://github.com/a/b", remote: "origin", server: URL(string: "http://github.com")!))
    XCTAssertThrowsError(try HostingRepository(remoteURL: "https://github.com/a/b", remote: "origin", server: URL(string: "https://secret@example.test")!))
    let finished = DispatchSemaphore(value: 0)
    var failure: Error?
    Task.detached {
      defer { finished.signal() }
      do {
        for context in [github, gitlab] {
          let gh = context.provider == .github
          let configuration = URLSessionConfiguration.ephemeral
          configuration.protocolClasses = [HostingFixtureProtocol.self]
          let session = URLSession(configuration: configuration)
          let token = "test-only-secret"
          let client = HostingClient(repository: context, token: token, session: session)
          let detail: [String: Any] = gh
            ? ["number": 7, "node_id": "PR_fixture", "title": "Review", "body": "Body", "html_url": "https://github.com/owner/repo/pull/7", "user": ["login": "author"], "state": "open", "draft": false,
              "head": ["ref": "feature", "sha": "head"], "base": ["ref": "main", "sha": "base"]]
            : ["iid": 7, "title": "Review", "description": "Body", "web_url": "https://gitlab.example/group/subgroup/repo/-/merge_requests/7", "author": ["username": "author"], "state": "opened", "draft": false,
              "source_branch": "feature", "target_branch": "main", "sha": "head", "diff_refs": ["base_sha": "base", "start_sha": "start", "head_sha": "head"]]
          let review = try HostedRequest(json: detail, provider: context.provider)
          var observed: [URLRequest] = []
          HostingFixtureProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: gh ? "Authorization" : "PRIVATE-TOKEN"), gh ? "Bearer " + token : token)
            XCTAssertFalse(request.url!.absoluteString.contains(token))
            observed.append(request)
            let path = request.url!.path
            if request.httpMethod == "GET", path.hasSuffix("/7") { return (200, detail) }
            if request.httpMethod == "GET", path.hasSuffix(gh ? "/pulls" : "/merge_requests") { return (200, [detail]) }
            if path.hasSuffix("/files") || path.hasSuffix("/diffs") {
              return (200, gh ? [["filename": "new.swift", "previous_filename": "old.swift", "patch": "@@ -1 +1 @@\n-old\n+new", "status": "renamed"]]
                : [["new_path": "new.swift", "old_path": "old.swift", "diff": "@@ -1 +1 @@\n-old\n+new"]])
            }
            if request.httpMethod == "GET", path.hasSuffix("/comments") || path.hasSuffix("/notes") {
              return (200, [["id": 10, "body": "Comment", gh ? "user" : "author": [gh ? "login" : "username": "reviewer"]]])
            }
            if path.hasSuffix("/merge") { return (200, gh ? ["merged": true] : ["state": "merged"]) }
            if request.httpMethod == "POST", path.hasSuffix(gh ? "/pulls" : "/merge_requests") { return (201, detail) }
            return (200, [:])
          }
          let list = try await client.list()
          XCTAssertEqual(list.first?.number, 7)
          let loaded = try await client.details(7)
          XCTAssertEqual(loaded.headSHA, "head")
          let files = try await client.files(7)
          XCTAssertEqual(files.first?.oldPath, "old.swift")
          let comments = try await client.comments(7)
          XCTAssertEqual(comments.first?.author, "reviewer")
          _ = try await client.create(title: "Title", body: "Description", source: "feature", target: "main", draft: true)
          try await client.comment(7, body: "Review comment")
          try await client.review(review, action: "APPROVE", body: "Looks good")
          try await client.lineComment(review, path: "new.swift", oldPath: "old.swift", line: 12, left: false, body: "Inline")
          try await client.merge(review, method: "squash")
          try await client.setState(7, open: false)
          try await client.edit(7, title: "Edited", body: "Edited body")
          let writes = observed.filter { $0.httpMethod != "GET" }
          XCTAssertEqual(writes.count, 7)
          func body(_ request: URLRequest) throws -> [String: Any] {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
              stream.open(); defer { stream.close() }
              var bytes = [UInt8](repeating: 0, count: 4096); var collected = Data()
              while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; collected.append(bytes, count: count) }
              data = collected
            }
            return try JSONSerialization.jsonObject(with: data!) as! [String: Any]
          }
          let creation = try body(writes[0])
          XCTAssertEqual(creation[gh ? "head" : "source_branch"] as? String, "feature")
          if gh { XCTAssertEqual(creation["draft"] as? Bool, true) }
          else { XCTAssertEqual(creation["title"] as? String, "Draft: Title") }
          let inline = try body(writes[3])
          if gh { XCTAssertEqual(inline["line"] as? Int, 12); XCTAssertEqual(inline["side"] as? String, "RIGHT") }
          else {
            let position = inline["position"] as! [String: Any]
            XCTAssertEqual(position["new_line"] as? Int, 12); XCTAssertEqual(position["start_sha"] as? String, "start")
            XCTAssertEqual(position["old_path"] as? String, "old.swift")
          }
          XCTAssertEqual(try body(writes[4])["sha"] as? String, "head")
          HostingFixtureProtocol.install { _ in (403, ["message": "Permission denied " + token]) }
          var rejected = false
          do { _ = try await client.list() }
          catch { rejected = true; XCTAssertFalse(error.localizedDescription.contains(token)) }
          XCTAssertTrue(rejected)
        }
      } catch { failure = error }
    }
    guard finished.wait(timeout: .now() + 45) == .success else { throw GitFailure("Hosting fixtures timed out.") }
    if let failure { throw failure }
  }
}

extension GitRepositoryTests {
  func testHostingReviewContracts() throws {
    let finished = DispatchSemaphore(value: 0)
    var failure: Error?
    Task.detached {
      defer { finished.signal() }
      do {
        for provider in HostingProvider.allCases {
          let gh = provider == .github
          let context = try HostingRepository(remoteURL: "https://\(provider.rawValue).example/team/repository.git", remote: "origin", provider: provider)
          let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HostingFixtureProtocol.self]
          let client = HostingClient(repository: context, token: "fixture", session: URLSession(configuration: configuration))
          let review = try HostedRequest(json: gh ? ["number": 7, "node_id": "PR_fixture", "title": "Review", "html_url": "https://github.example/team/repository/pull/7", "head": ["sha": "head"]]
            : ["iid": 7, "title": "Draft: Review", "web_url": "https://gitlab.example/team/repository/-/merge_requests/7", "sha": "head"], provider: provider)
          var operations: [(String, String, [String: Any])] = []
          HostingFixtureProtocol.install { request in
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
              stream.open(); defer { stream.close() }
              var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
              while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; collected.append(buffer, count: count) }
              data = collected
            }
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            operations.append((request.url!.path, request.httpMethod ?? "GET", body))
            let path = request.url!.path
            if path.hasSuffix("/graphql"), (body["query"] as? String)?.hasPrefix("query") == true {
              let comment: [String: Any] = ["databaseId": 55, "body": "Inline comment", "author": ["login": "reviewer"]]
              let thread: [String: Any] = ["id": "thread1", "path": "file.swift", "line": 4, "isResolved": false, "viewerCanResolve": true, "comments": ["nodes": [comment]]]
              let connection: [String: Any] = ["pageInfo": ["hasNextPage": false], "nodes": [thread]]
              return (200, ["data": ["repository": ["pullRequest": ["reviewThreads": connection]]]])
            }
            if path.hasSuffix("/discussions"), request.httpMethod == "GET" {
              return (200, [["id": "thread1", "notes": [["id": 55, "resolvable": true, "resolved": false, "body": "Inline comment", "author": ["username": "reviewer"], "position": ["new_path": "file.swift", "new_line": 4]]]]])
            }
            if path.hasSuffix("/users") { return (200, [["id": 88]]) }
            if path.hasSuffix("/gists") || path.hasSuffix("/snippets") { return (201, [gh ? "html_url" : "web_url": "https://\(provider.rawValue).example/snippets/9"]) }
            if path.hasSuffix("/status") { return (200, ["statuses": [["context": "build", "state": "success"]]]) }
            if path.hasSuffix("/check-runs") { return (200, ["check_runs": [["name": "tests", "conclusion": "success"]]]) }
            if path.hasSuffix("/pipelines") { return (200, [["id": 1, "status": "success"]]) }
            return (200, [:])
          }
          let threads = try await client.threads(7)
          XCTAssertEqual(threads.count, 1); XCTAssertEqual(threads.first?.firstCommentID, 55)
          XCTAssertTrue(threads.first?.canResolve == true)
          try await client.reply(7, thread: threads[0], body: "Reply")
          try await client.resolve(7, thread: threads[0])
          try await client.setDraft(review, draft: false)
          try await client.requestReviewers(7, usernames: ["reviewer"])
          let snippet = try await client.createSnippet(title: "Snippet", files: ["file.swift": "let x = 1"], isPublic: false)
          XCTAssertTrue(snippet.path.hasSuffix("/9"))
          let status = try await client.status(review)
          XCTAssertTrue(status.contains("success"))
          XCTAssertTrue(operations.contains { $0.0.hasSuffix(gh ? "/comments/55/replies" : "/discussions/thread1/notes") && $0.2["body"] as? String == "Reply" })
          if gh {
            XCTAssertTrue(operations.contains { ($0.2["query"] as? String)?.contains("resolveReviewThread") == true })
            XCTAssertTrue(operations.contains { ($0.2["query"] as? String)?.contains("markPullRequestReadyForReview") == true })
            XCTAssertTrue(operations.contains { $0.0.hasSuffix("/requested_reviewers") && $0.2["reviewers"] as? [String] == ["reviewer"] })
            XCTAssertTrue(operations.contains { $0.0.hasSuffix("/gists") && $0.2["public"] as? Bool == false })
            HostingFixtureProtocol.install { _ in (200, ["merged": false, "message": "Branch protection refused the merge"]) }
            var rejected = false
            do { try await client.merge(review, method: "merge") } catch { rejected = true }
            XCTAssertTrue(rejected)
          } else {
            XCTAssertTrue(operations.contains { $0.0.hasSuffix("/discussions/thread1") && $0.2["resolved"] as? Bool == true })
            XCTAssertTrue(operations.contains { $0.2["title"] as? String == "Review" })
            XCTAssertTrue(operations.contains { $0.2["reviewer_ids"] as? [Int] == [88] })
            XCTAssertTrue(operations.contains { $0.0.hasSuffix("/snippets") && $0.2["visibility"] as? String == "private" })
          }
        }
      } catch { failure = error }
    }
    guard finished.wait(timeout: .now() + 45) == .success else { throw GitFailure("Hosting review fixtures timed out.") }
    if let failure { throw failure }
  }
}
