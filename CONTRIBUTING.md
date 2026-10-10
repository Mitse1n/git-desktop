# Contributing to GitDesk

Issues and pull requests in English or Chinese are welcome.

## Report a bug or suggest a feature

Search [existing issues](https://github.com/Mitse1n/git-desktop/issues) first. For bugs, include your macOS version, CPU architecture, Swift and Git versions, the commit you built, steps to reproduce, expected behavior, and actual behavior. A small disposable repository or reproduction script is especially useful for Git behavior bugs.

Remove private paths, remote URLs, credentials, commit messages, and personal data from screenshots or Console output before posting. Follow [SECURITY.md](SECURITY.md) for sensitive reports. For large changes, open an issue to agree on scope before implementation.

## Development environment

Use macOS 14+ with Swift 6.0+ and system Git. Xcode Command Line Tools are sufficient when they provide a compatible Swift compiler.

```sh
git clone https://github.com/Mitse1n/git-desktop.git
cd git-desktop
swift build
./scripts/test.sh
./scripts/create-demo.sh
swift run GitDesk /tmp/gitdesk-demo
```

Fork the repository and create a topic branch. There are no package dependencies to install.

## Make a change

- Keep Git processes, parsing, models, graph layout, and text diffs in `GitDeskCore`; keep AppKit code in `GitDesk`.
- Follow the surrounding Swift style: two-space indentation and explicit error handling.
- Pass Git arguments through the existing process wrapper. Keep filename handling literal and NUL-safe, and preserve the index and working tree outside the user's selection.
- Run repository-changing checks in disposable repositories, with local bare remotes when needed.
- For core behavior fixes, add a regression case to `Tests/GitDeskCoreTests/GitRepositoryTests.swift` and register it in `main.swift`. The checks are a custom executable; `swift test` does not run them.
- For UI changes, exercise the affected flow in the demo repository and include screenshots. State what you actually checked.
- Update both README languages when changing features, requirements, or instructions. Record notable changes under `Unreleased` in the changelog.

## Validate and open a pull request

```sh
./scripts/test.sh
./scripts/build-app.sh
codesign --verify --deep --strict dist/GitDesk.app
git diff --check
```

Describe the problem, resulting behavior, and validation. Keep the PR focused; do not commit `.build/`, `dist/`, credentials, or local editor state. GitHub Actions runs regression checks and app packaging on macOS.

Be respectful, discuss the code rather than the person, and avoid harassment or sharing private information. Maintainers may edit or remove abusive content and close off-topic contributions.

Original contributions are submitted under the project's [MIT License](LICENSE). Preserve attribution for third-party material.

## 中文说明

欢迎使用中文提交 Issue 和 PR。请先查找已有问题，提供环境、复现步骤、预期与实际结果。Git 行为问题尽量提供可丢弃的最小复现仓库；发布截图或日志前删除敏感信息。

核心行为修复应补充并注册回归用例，UI 改动请在演示仓库实际检查并附图。提交前运行测试、打包、签名验证和空白检查，更新相关中英文文档。请保持讨论友善，原创贡献采用项目 MIT 许可。
