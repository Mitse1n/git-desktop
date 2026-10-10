#!/bin/zsh
set -eu
DEMO_ROOT="${1:-/tmp/gitdesk-demo}"
if [[ -e "$DEMO_ROOT" ]]; then
  print "Demo already exists: $DEMO_ROOT"
  exit 0
fi
mkdir -p "$DEMO_ROOT"
cd "$DEMO_ROOT"
git init -b main -q
git config user.name 'Alex Chen'
git config user.email 'alex@example.test'
mkdir -p Sources Tests
print '# GitDesk\n\nA lightweight native Git client.' > README.md
print 'struct Repository {\n    let name: String\n}' > Sources/Repository.swift
git add .
git commit -qm 'Initial commit'
git switch -qc feature/branch-search
print 'struct BranchFilter {\n    var query = ""\n    func matches(_ branch: String) -> Bool {\n        branch.localizedCaseInsensitiveContains(query)\n    }\n}' > Sources/BranchFilter.swift
git add .
git commit -qm 'Add branch search and filtering'
print '// Branch search coverage' > Tests/BranchFilterTests.swift
git add .
git -c user.name='Maya Lin' -c user.email='maya@example.test' commit -qm 'Cover branch search edge cases'
git switch -q main
print '\n## Features\n\nCommit history, branches, and side-by-side diffs.' >> README.md
git add .
git commit -qm 'Document the Git workflow'
git merge --no-ff feature/branch-search -qm 'Merge branch search into main'
git tag v0.1.0
git branch release/0.1
print '\n## Getting started\n\nOpen a local repository to begin.' >> README.md
git add .
git -c user.name='Maya Lin' -c user.email='maya@example.test' commit -qm 'Add getting started instructions'
print 'struct Repository {\n    let name: String\n    let path: String\n\n    var displayName: String { name }\n}' > Sources/Repository.swift
print '# Local notes\n\nReview the new repository model.' > Notes.md
print "$DEMO_ROOT"
