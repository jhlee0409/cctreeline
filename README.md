# cctreeline

[![License: MIT](https://img.shields.io/github/license/jhlee0409/cctreeline)](LICENSE)
[![shellcheck](https://github.com/jhlee0409/cctreeline/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/jhlee0409/cctreeline/actions/workflows/shellcheck.yml)
![GitHub stars](https://img.shields.io/github/stars/jhlee0409/cctreeline?style=social)

A [Claude Code](https://claude.com/claude-code) statusline for people who run **multiple git worktrees** and **parallel Claude sessions**.

Most statuslines tell you about *one* repo. `cctreeline` adds a third line that, for **only the worktrees you actually edited in the current session**, shows each one's open PR numbers — a view nothing else in the ecosystem gives you.

```
12m · myapp/server · main ⌂main ●3 +1 ↑2 · Opus 4.8 1M · id:a1b2c3d4-e5f6
ctx ███░░░░░░░ 31% · 7d·Opus █████░░░░░ 58% 2d3h · 5h-42% 3h12m
⎇ feature-auth      PR: #142
⎇ hotfix-payments   PR: #143 #144
```

- **Line 1** — session duration · repo-relative path · branch + **worktree badge** (`⌂main` vs `⎇wt(parent)`) + dirty marks (`●` modified, `+` staged, `↑` ahead) · model + **1M-context** badge · session id
- **Line 2** — context-window gauge · **weekly** limit (auto-binding, per-model scope tag like `7d·Opus`) · **5h** rolling limit, each with a reset countdown
- **Line 3** — per-worktree open-PR overview, **scoped to the worktrees edited this session**

## Why another statusline?

There are excellent general-purpose statuslines — [ccstatusline](https://github.com/sirmalloc/ccstatusline), [claude-hud](https://github.com/jarrodwatts/claude-hud), [claude-powerline](https://github.com/Owloops/claude-powerline). `cctreeline` is **not** trying to beat them on breadth, themes, or a config TUI. It does one thing they don't:

> It joins **worktree** (main vs linked + parent repo) × **open PR number** × **files you edited this session**.

If you run several worktrees in parallel (one per task/PR) and bounce between Claude sessions, line 3 is your at-a-glance "which of my in-flight branches have PRs, and which did I touch just now." If you only ever use one worktree, you don't need this — use ccstatusline.

Two secondary niceties:

- **No `npx … @latest` in the render hot path.** Pure `bash` + `jq`. The render runs no network, downloads nothing, and pins no moving version — it just reads cache files that refresh in the background. (Some npm-based statuslines re-resolve a package on every frame.)
- **Auto-binding weekly gauge.** One gauge that picks whichever weekly bucket is currently binding (per `/status`) and labels its model scope — instead of N fixed gauges. *(Caveat: the per-model scope relies on the OAuth usage API returning a `limits[]` array; where it doesn't, cctreeline falls back to a flat `7d` gauge. See [Limitations](#limitations).)*

## Install

Requires `bash`, `jq`, `git`. Optional: `gh` (PR numbers on line 3), `curl` (usage gauges), `timeout`/`gtimeout` from coreutils (bounds the `gh` call; stock on Linux, `brew install coreutils` on macOS — without it the PR fetch runs unbounded).

```bash
git clone https://github.com/jhlee0409/cctreeline
cd cctreeline
bash install.sh
```

The installer auto-detects your OS, date flavor, credential store, and dependencies, then asks **up to four** questions:

1. **Enable 5h / weekly usage gauges?** — reads your Claude credentials (macOS Keychain or `~/.claude/.credentials.json`) and calls `api.anthropic.com`. *(Only asked when credentials **and** `curl` are present; skipped otherwise.)*
2. **Enable the worktree + PR line?** — needs `gh` for PR numbers.
3. **Use ASCII glyphs?** — for terminals without box-drawing fonts.
4. **Compact line 2?** — show only `ctx` + `5h`, hide weekly/output-style.

Everything else is detected. It backs up your `settings.json` and won't overwrite an existing statusline without asking.

Non-interactive (`bash install.sh --defaults`, or any no-TTY run) uses safe defaults and keeps the credential-reading gauge **off** unless you pass `--enable-usage`.

### Manual install

```jsonc
// ~/.claude/settings.json
{ "statusLine": { "type": "command", "command": "bash /path/to/cctreeline.sh" } }
```

## Configuration

`${XDG_CONFIG_HOME:-~/.config}/cctreeline/config` (shell key=value):

| Key | Values | Default | Meaning |
|---|---|---|---|
| `CCTREELINE_USAGE_GAUGES` | `1` / `0` | `1` | Read credentials + show 5h/weekly gauges |
| `CCTREELINE_WORKTREE_LINE` | `1` / `0` / `auto` | `auto` | Line 3 (`auto` = on inside a git repo) |
| `CCTREELINE_COLOR` | `auto` / `256` / `none` | `auto` | `auto` honors `NO_COLOR` and `TERM=dumb` |
| `CCTREELINE_GLYPHS` | `unicode` / `ascii` | `unicode` | Glyph set |
| `CCTREELINE_DENSITY` | `full` / `compact` | `full` | `compact` = ctx + 5h only |
| `CCTREELINE_REUSE_HUD_CACHE` | `auto` / `0` | `auto` | Reuse claude-hud's usage cache if present (avoids a duplicate API call) |

## How it works

The render path (`cctreeline.sh` with no args) only reads stdin JSON and cache files, so it's fast and offline. Two background refreshers keep the caches warm (single-flight locked, TTL'd):

- `cctreeline.sh --refresh-usage` — calls the OAuth usage API, writes `~/.cache/cctreeline/usage.json` (60s TTL)
- `cctreeline.sh --refresh-worktrees <cwd>` — `git worktree list` + `gh pr list`, writes `~/.cache/cctreeline/worktrees.json` (120s TTL)

You never invoke these; the render path fires them via `nohup` when a cache goes stale.

## Limitations

- **Per-model weekly scope** depends on the OAuth usage API exposing a `limits[]` array with weekly buckets. On accounts/regions where the endpoint returns only a flat `seven_day` value, the gauge degrades to a plain `7d` (no model tag). This is an undocumented API surface — treat the scope tag as best-effort.
- **No cost / $ display, no themes, no config TUI.** By design — this is a focused tool, not a framework. If you want those, ccstatusline / claude-powerline are better.
- The worktree line (line 3) only appears for linked worktrees whose files you **edited this session** (the main repo is excluded). If you have no linked worktrees — or didn't edit any this session — line 3 is simply omitted (not a blank line). It's most useful when you run several worktrees in parallel.

## Uninstall

The installer touches four places; to fully remove cctreeline:

```bash
# 1. restore your statusline — either from the timestamped backup the installer made…
ls ~/.claude/settings.json.cctreeline-bak.*        # pick the right one
cp ~/.claude/settings.json.cctreeline-bak.<epoch> ~/.claude/settings.json
#    …or, if cctreeline was your only statusline, just drop the key:
#    jq 'del(.statusLine)' ~/.claude/settings.json | sponge ~/.claude/settings.json

# 2. remove the runtime, config, and cache (respect XDG_*/CLAUDE_CONFIG_DIR if you set them)
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/cctreeline" \
       "${XDG_CONFIG_HOME:-$HOME/.config}/cctreeline" \
       "${XDG_CACHE_HOME:-$HOME/.cache}/cctreeline"
```

## Acknowledgements

The 5h/weekly usage refresh mirrors the OAuth-usage approach of [claude-hud](https://github.com/jarrodwatts/claude-hud) (MIT, by Jarrod Watts), and will reuse its usage cache if present to avoid a duplicate API call. Thanks also to [ccstatusline](https://github.com/sirmalloc/ccstatusline) and [claude-powerline](https://github.com/Owloops/claude-powerline) for charting the Claude Code statusline space.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
