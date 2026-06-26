# Security

## What cctreeline accesses

cctreeline is a local statusline script. When you **opt in** to usage gauges, it:

- reads your Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`) or `~/.claude/.credentials.json`;
- sends that token only to its issuer, `https://api.anthropic.com/api/oauth/usage`, over HTTPS to read your rate-limit utilization;
- passes the token to `curl` via a stdin config (`-K -`), never on the command line, so it is not visible in `ps`.

The token is **never** written to disk, logged, or stored in any cache file. Only utilization percentages and reset times are cached (`~/.cache/cctreeline/`). If you decline usage gauges, no credential is read and no network call is made.

The installer also modifies `~/.claude/settings.json` (to register the statusline) after backing it up, and the runtime sources `~/.config/cctreeline/config` as shell — treat that config file as trusted (it is yours).

## Reporting a vulnerability

Please report security issues privately via GitHub's **"Report a vulnerability"** (repo → Security → Advisories), not in a public issue. I'll acknowledge within a few days.
