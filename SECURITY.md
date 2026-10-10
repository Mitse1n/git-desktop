# Security policy

GitDesk is in early development. Security fixes are made on `main`; there is no commitment to backport fixes to older snapshots.

## Reporting a vulnerability

Do not put credentials, private repository contents, or an exploit containing sensitive data in a public issue.

If the repository's **Security → Report a vulnerability** option is available, use it for a private report. Otherwise, open a minimal issue asking the maintainer to arrange a private reporting channel, without including vulnerability details. No response-time guarantee is currently offered.

A useful private report includes the affected commit, macOS and Git versions, reproduction steps using a disposable repository, impact, and a suggested fix if available.

## Relevant behavior

- GitDesk invokes `/usr/bin/git`, inheriting the process environment and using existing Git configuration, SSH, and credential helpers. Git hooks and external helpers can run according to that configuration; only open repositories and use configurations you trust.
- Remote commands run without interactive terminal input. Configure authentication outside the app first.
- Recent repository paths and commit-message history are stored locally in macOS user defaults. Console output can contain repository details. Remove sensitive data before sharing logs or screenshots.
- Locally built bundles use ad-hoc signing. They are not Developer ID signed or notarized.

## 中文说明

安全修复在 `main` 分支进行，目前不承诺旧版本回补。请勿在公开 Issue 中披露凭据、私有仓库内容或敏感漏洞细节。若 GitHub 提供 **Security → Report a vulnerability**，请使用私密报告；否则先通过不含漏洞细节的 Issue 请求维护者安排私密沟通渠道。

应用复用 Git 配置、hooks、SSH 和 credential helper；最近仓库路径及提交消息历史保存在本机。分享日志、截图前请移除敏感内容。
