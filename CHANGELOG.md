# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses [SemVer](https://semver.org/).

## [Unreleased]

### Changed
- Follow the Claude Code 2.1 statusLine stdin schema:
  - ctx gauge reads `context_window.used_percentage`; transcript parsing is now only a fallback.
  - 1M badge comes from `context_window.context_window_size` (no longer guessed from the model name or `exceeds_200k_tokens`, which is a fixed 200k threshold). Fixes ctx showing ~5x too high on 1M models whose display name has no "1M" (e.g. `Opus 5.5`).
  - 5h / weekly gauges read `rate_limits.five_hour` / `seven_day` (epoch-second `resets_at`). The OAuth usage API is called only when stdin has no `rate_limits`.
- Line 3 also counts a worktree as worked in when a `Bash` command names its path, not only when a file there was edited.
- The worktree cache is per repository (`worktrees-<repo>-<cksum>.json`), so switching repos no longer mixes their worktree lists.
- Installer Q1 now describes the usage API as a fallback. Re-running the installer keeps config keys it doesn't ask about (e.g. `CCTREELINE_PLAN`).
- README rewritten: quick start, line-by-line table, flow diagram, what-it-reads/sends table, troubleshooting. Demo feeds the 2.1 stdin schema with an isolated `HOME` and no seeded usage cache; GIF regenerated.

### Added
- Line 1: effort level (`nothink` / `fast` when set), `agent:` name, `+Ndir` for added dirs, signed-in account (`CCTREELINE_ACCOUNT`), session name.
- Line 2: prompt-cache time left / `cold`, compactions (`cmp N`, `CCTREELINE_COMPACTIONS`), session cost with plan tag (`Max20x·$3.12`, `CCTREELINE_COST`, `CCTREELINE_PLAN`).
- `tests/render_test.sh` with a recorded Claude Code 2.1.332 payload, the documented example, and sandboxed account/plan/worktree scenarios; run in CI.

### Fixed
- Usage and worktree refresh locks were never removed: the EXIT trap referenced `local` variables that were already out of scope.
- Usage refresh no longer drops the weekly value when the API reports no 5h window.

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
