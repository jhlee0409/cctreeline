#!/usr/bin/env bash
# Self-contained cctreeline demo render — used by demo/demo.tape (vhs), and
# runnable standalone to preview. Builds an isolated temp git repo + seeded
# GENERIC caches (no real credentials, no API call; nothing in your ~/.claude
# is read or written). Cleans up after itself.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# canonical path (pwd -P) so macOS $TMPDIR symlinks don't bloat the line-1 path
DEMO=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cctreeline-demo.XXXXXX")" && pwd -P)
trap 'rm -rf "$DEMO"' EXIT

# portable "now + N seconds" as an RFC3339 UTC stamp (GNU or BSD date)
iso_in() {
  local t=$(( $(date +%s) + $1 ))
  date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ
}

# 1) a small git repo "myapp" on branch main with a couple of dirty marks
repo="$DEMO/myapp"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" symbolic-ref HEAD refs/heads/main
git -C "$repo" config user.email demo@example.com
git -C "$repo" config user.name  demo
printf 'a\n' > "$repo/a.txt"; printf 'b\n' > "$repo/b.txt"; printf 'c\n' > "$repo/c.txt"
git -C "$repo" add a.txt b.txt c.txt
git -C "$repo" commit -qm init
printf 'edit\n' >> "$repo/a.txt"                          # modified → ●
printf 'edit\n' >> "$repo/b.txt"                          # modified → ●
printf 'new\n'  >  "$repo/d.txt"; git -C "$repo" add d.txt # staged   → +

# 2) seeded caches (generic) under an isolated XDG home
mkdir -p "$DEMO/cache/cctreeline" "$DEMO/config/cctreeline"
mkdir -p "$DEMO/wt-feature-auth/src" "$DEMO/wt-hotfix-payments/src"
now=$(( $(date +%s) * 1000 ))
cat > "$DEMO/cache/cctreeline/usage.json" <<EOF
{"data":{"fiveHour":42,"fiveHourResetAt":"$(iso_in 11520)","weeklyBindingPct":58,"weeklyBindingScope":"Opus","weeklyBindingResetAt":"$(iso_in 183600)"},"timestamp":$now}
EOF
cat > "$DEMO/cache/cctreeline/worktrees.json" <<EOF
{"worktrees":[
 {"name":"myapp-feature-auth","slug":"feature-auth","branch":"feature-auth","path":"$DEMO/wt-feature-auth","prs":[142]},
 {"name":"myapp-hotfix-payments","slug":"hotfix-payments","branch":"hotfix-payments","path":"$DEMO/wt-hotfix-payments","prs":[143,144]}
],"timestamp":$now}
EOF
cat > "$DEMO/config/cctreeline/config" <<EOF
CCTREELINE_USAGE_GAUGES=1
CCTREELINE_WORKTREE_LINE=1
CCTREELINE_COLOR=256
CCTREELINE_GLYPHS=unicode
CCTREELINE_DENSITY=full
CCTREELINE_REUSE_HUD_CACHE=0
EOF

# 3) transcript: context usage + edits in BOTH worktrees this session
cat > "$DEMO/transcript.jsonl" <<EOF
{"type":"assistant","message":{"usage":{"input_tokens":70000,"cache_read_input_tokens":230000,"cache_creation_input_tokens":10000}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"$DEMO/wt-feature-auth/src/login.ts"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"$DEMO/wt-hotfix-payments/src/charge.ts"}}]}}
EOF

# 4) the JSON Claude Code feeds the statusline on stdin
STDIN='{"workspace":{"current_dir":"'"$repo"'"},"transcript_path":"'"$DEMO"'/transcript.jsonl","session_id":"a1b2c3d4-e5f67890","model":{"display_name":"Opus 4.8 (1M context)","id":"claude-opus-4-8[1m]"},"output_style":{"name":"default"},"cost":{"total_duration_ms":740000}}'

printf '\n'
printf '  \033[2m# the statusline Claude Code renders below your prompt:\033[0m\n\n'
echo "$STDIN" | XDG_CACHE_HOME="$DEMO/cache" XDG_CONFIG_HOME="$DEMO/config" bash "$ROOT/cctreeline.sh" | sed 's/^/  /'
printf '\n'
