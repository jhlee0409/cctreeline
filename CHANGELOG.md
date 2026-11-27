# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses [SemVer](https://semver.org/).

## [Unreleased]

### Changed
- Follow the Claude Code 2.1 statusLine stdin schema:
  - ctx gauge reads `context_window.used_percentage`; transcript parsing is now only a fallback.
  - 1M badge comes from `context_window.context_window_size` (no longer guessed from the model name or `exceeds_200k_tokens`, which is a fixed 200k threshold). Fixes ctx showing ~5x too high on 1M models whose display name has no "1M" (e.g. `Opus 5.5`).
  - 5h / weekly gauges read `rate_limits.five_hour` / `seven_day` (epoch-second `resets_at`). The OAuth usage API is called only when stdin lacks a window.
- Installer Q1 now describes the usage API as a fallback.

### Added
- `tests/render_test.sh` with a recorded Claude Code 2.1.332 payload and the documented example; run in CI.

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
