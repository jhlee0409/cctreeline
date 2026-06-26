#!/usr/bin/env bash
# treeline installer — detects what it can, asks only what it must.
#
# Asks 3 things: (1) usage gauges [reads your Claude credentials], (2) the
# worktree+PR line, (3) color/glyphs. Everything else (OS, date flavor,
# credential store, dependencies, plan) is auto-detected.
#
# Honors XDG_CONFIG_HOME / XDG_DATA_HOME / CLAUDE_CONFIG_DIR so it can be run
# against a sandbox without touching your real setup.
#
#   bash install.sh            interactive
#   bash install.sh --defaults non-interactive, smart defaults (CI / dotfiles)

set -euo pipefail

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/treeline"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/treeline"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
INSTALLED="$DATA_DIR/treeline.sh"
CONFIG_FILE="$CONFIG_DIR/config"

NONINTERACTIVE=0
[ "${1:-}" = "--defaults" ] && NONINTERACTIVE=1
[ -t 0 ] || NONINTERACTIVE=1   # no TTY → defaults

bold=$(printf '\033[1m'); dim=$(printf '\033[2m'); grn=$(printf '\033[32m')
ylw=$(printf '\033[33m'); red=$(printf '\033[31m'); rst=$(printf '\033[0m')
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$grn" "$rst" "$*"; }
warn() { printf '%s!%s %s\n' "$ylw" "$rst" "$*"; }
err()  { printf '%s✗%s %s\n' "$red" "$rst" "$*" >&2; }

# yes/no prompt with a default; honors NONINTERACTIVE
ask_yn() {
  local prompt="$1" def="$2" ans
  if [ "$NONINTERACTIVE" = "1" ]; then [ "$def" = "y" ] && return 0 || return 1; fi
  local hint="[y/N]"; [ "$def" = "y" ] && hint="[Y/n]"
  read -r -p "$prompt $hint " ans </dev/tty || ans=""
  ans="${ans:-$def}"
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

say "${bold}treeline installer${rst}"
say "${dim}a Claude Code statusline for multi-worktree workflows${rst}"
say ""

# ── 1. dependencies (auto, abort only on hard requirement) ──────
say "${bold}Checking dependencies${rst}"
MISSING=0
if command -v jq  >/dev/null 2>&1; then ok "jq    $(command -v jq)"; else err "jq is REQUIRED — install it (brew install jq / apt install jq)"; MISSING=1; fi
if command -v git >/dev/null 2>&1; then ok "git   $(command -v git)"; else err "git is REQUIRED"; MISSING=1; fi
HAS_CURL=0; if command -v curl >/dev/null 2>&1; then ok "curl  $(command -v curl)"; HAS_CURL=1; else warn "curl missing — usage gauges (5h/weekly) will be unavailable"; fi
HAS_GH=0;   if command -v gh   >/dev/null 2>&1; then ok "gh    $(command -v gh)";   HAS_GH=1;   else warn "gh missing — worktree line can't show PR numbers (worktrees still listed)"; fi
[ "$MISSING" = "1" ] && { err "Missing required dependencies. Aborting."; exit 1; }

# ── 2. platform (auto) ──────────────────────────────────────────
say ""
say "${bold}Detecting platform${rst}"
case "$(uname -s)" in Darwin) OS=macOS; IS_MAC=1 ;; Linux) OS=Linux; IS_MAC=0 ;; *) OS=$(uname -s); IS_MAC=0 ;; esac
if date --version >/dev/null 2>&1; then DATEK="GNU"; else DATEK="BSD"; fi
ok "OS: $OS   date: $DATEK"

# credential source detection (for usage gauges)
CRED_OK=0; CRED_SRC="none"
if [ "$IS_MAC" = "1" ] && command -v security >/dev/null 2>&1; then
  if /usr/bin/security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
    CRED_OK=1; CRED_SRC="macOS Keychain"
  fi
fi
if [ "$CRED_OK" = "0" ]; then
  for f in "$CLAUDE_DIR/.credentials.json" "$HOME/.claude/.credentials.json"; do
    [ -f "$f" ] && { CRED_OK=1; CRED_SRC="$f"; break; }
  done
fi
if [ "$CRED_OK" = "1" ]; then ok "Claude credentials: $CRED_SRC"; else warn "Claude credentials not found — usage gauges will be off"; fi

# ── 3. THE questions (only what we can't infer) ─────────────────
say ""
say "${bold}Configuration${rst}"

# Q1 — usage gauges (consent: reads creds + calls the Anthropic usage API)
USAGE=0
if [ "$CRED_OK" = "1" ] && [ "$HAS_CURL" = "1" ]; then
  say "${dim}Usage gauges show your 5-hour and weekly rate-limit %.${rst}"
  say "${dim}This reads your Claude credentials ($CRED_SRC) and calls api.anthropic.com.${rst}"
  if ask_yn "Enable 5h / weekly usage gauges?" "y"; then USAGE=1; fi
else
  warn "Skipping usage gauges (need credentials + curl)."
fi

# Q2 — worktree+PR line (the differentiator)
WTLINE=auto
say ""
say "${dim}Line 3 lists each git worktree you edited THIS session + its open PRs.${rst}"
if [ "$HAS_GH" = "0" ]; then say "${dim}(gh not found — worktrees will list without PR numbers.)${rst}"; fi
if ask_yn "Enable the worktree + PR line?" "y"; then WTLINE=1; else WTLINE=0; fi

# Q3 — color + glyphs (auto-default, override on request)
COLOR=auto; GLYPHS=unicode
say ""
if [ -n "${NO_COLOR:-}" ]; then COLOR=none; warn "NO_COLOR set → color disabled."; fi
if ask_yn "Use ASCII glyphs instead of unicode (for fonts without box-drawing)?" "n"; then GLYPHS=ascii; fi
DENSITY=full
if ask_yn "Compact line 2 (ctx + 5h only, hide weekly/output-style)?" "n"; then DENSITY=compact; fi

# ── 4. install files ────────────────────────────────────────────
say ""
say "${bold}Installing${rst}"
mkdir -p "$CONFIG_DIR" "$DATA_DIR"
cp "$SRC_DIR/treeline.sh" "$INSTALLED"; chmod +x "$INSTALLED"
ok "runtime → $INSTALLED"

cat > "$CONFIG_FILE" <<EOF
# treeline config — written by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "install")
# Re-run install.sh or edit by hand. Values: see README.
TREELINE_USAGE_GAUGES=$USAGE
TREELINE_WORKTREE_LINE=$WTLINE
TREELINE_COLOR=$COLOR
TREELINE_GLYPHS=$GLYPHS
TREELINE_DENSITY=$DENSITY
TREELINE_REUSE_HUD_CACHE=auto
EOF
ok "config  → $CONFIG_FILE"

# ── 5. wire into Claude Code settings.json (safe merge) ─────────
mkdir -p "$CLAUDE_DIR"
NEW_CMD="bash $INSTALLED"
if [ -f "$SETTINGS" ]; then
  # refuse to touch a settings.json we can't parse (don't risk truncating it)
  if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    err "$SETTINGS is not valid JSON — leaving it untouched. Fix it, then re-run."
    say "    To enable treeline by hand, add:"
    say "    \"statusLine\": { \"type\": \"command\", \"command\": \"$NEW_CMD\" }"
    exit 1
  fi
  EXISTING=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || echo "")
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "$NEW_CMD" ]; then
    warn "An existing statusLine is configured:"
    say  "    $EXISTING"
    if ! ask_yn "Replace it with treeline?" "n"; then
      warn "Left settings.json untouched. To enable treeline later, set:"
      say  "    \"statusLine\": { \"type\": \"command\", \"command\": \"$NEW_CMD\" }"
      say ""; ok "Done (statusline not wired)."; exit 0
    fi
  fi
  BACKUP="$SETTINGS.treeline-bak.$(date +%s 2>/dev/null || echo bak)"
  cp "$SETTINGS" "$BACKUP"; ok "backed up settings.json → $BACKUP"
  # tmp in the destination dir → mv is a same-filesystem atomic rename
  tmp=$(mktemp "$CLAUDE_DIR/settings.json.XXXXXX"); trap 'rm -f "$tmp"' EXIT
  if jq --arg cmd "$NEW_CMD" '.statusLine = {type:"command", command:$cmd}' "$SETTINGS" > "$tmp"; then
    mv "$tmp" "$SETTINGS"
  else
    err "Failed to update settings.json — left unchanged (backup at $BACKUP)."; exit 1
  fi
else
  # new file — build via jq so the path value is always correctly escaped
  jq -n --arg cmd "$NEW_CMD" '{statusLine:{type:"command", command:$cmd}}' > "$SETTINGS"
fi
ok "wired into $SETTINGS"

say ""
ok "${bold}treeline installed.${rst} Open a new Claude Code session to see it."
[ "$USAGE" = "0" ] && say "${dim}Usage gauges are off. Re-run install.sh after logging into Claude to enable.${rst}"
