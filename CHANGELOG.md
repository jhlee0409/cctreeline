# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-06-26

Initial release.

### Added
- Three-line Claude Code statusline:
  - line 1 — duration · repo-relative path · branch + worktree badge (`⌂main` / `⎇wt`) + dirty marks · model + 1M badge · session id
  - line 2 — context gauge · weekly limit (auto-binding, per-model scope) · 5h rolling limit, with reset countdowns
  - line 3 — per-worktree open-PR overview, scoped to the worktrees you edited this session
- Portability: auto-detects GNU/BSD `date`/`stat`, the platform credential store (macOS Keychain / `~/.claude/.credentials.json`), and a `timeout`/`gtimeout` runner; XDG paths; bash 3.2 compatible.
- `install.sh` — auto-detects environment, asks up to four questions, safe `settings.json` merge with backup; `--defaults` keeps the credential-reading gauge off unless `--enable-usage`.
- Config via `${XDG_CONFIG_HOME:-~/.config}/cctreeline/config`; color/glyph/density modes.

[Unreleased]: https://github.com/jhlee0409/cctreeline/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jhlee0409/cctreeline/releases/tag/v0.1.0
