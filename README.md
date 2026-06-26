# cctreeline

A [Claude Code](https://claude.com/claude-code) statusline for people who run **multiple git worktrees** and **parallel Claude sessions**.

Most statuslines tell you about *one* repo. `cctreeline` adds a third line that, for **only the worktrees you actually edited in the current session**, shows each one's open PR numbers — a view nothing else in the ecosystem gives you.

```
12m · myapp/backend · main ⌂main ●3 +1 ↑2 · Opus 4.8 1M · id:a1b2c3d4-e5f6
ctx ███░░░░░░░ 31% · 7d·Opus ██████░░░░ 58% 2d3h · 5h-42% 3h12m
⎇ feature-auth  PR: #142
⎇ hotfix-payments PR: #143 #144
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

Requires `bash`, `jq`, `git`. Optional: `gh` (PR numbers on line 3), `curl` (usage gauges).

```bash
git clone https://github.com/jhlee0409/cctreeline
cd cctreeline
bash install.sh
```

The installer auto-detects your OS, date flavor, credential store, and dependencies, then asks **three** questions:

1. **Enable 5h / weekly usage gauges?** — these read your Claude credentials (macOS Keychain or `~/.claude/.credentials.json`) and call `api.anthropic.com`. Off if you decline.
2. **Enable the worktree + PR line?** — needs `gh` for PR numbers.
3. **ASCII glyphs / compact mode?** — for terminals without box-drawing fonts.

Everything else is detected. It backs up your `settings.json` and won't overwrite an existing statusline without asking.

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
- The worktree line is only useful with **multiple worktrees**. Single-worktree users will see an empty line 3 (or turn it off).

## License

MIT
