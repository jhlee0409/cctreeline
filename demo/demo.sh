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

# "now + N seconds" as epoch seconds (rate_limits.*.resets_at uses epoch seconds)
epoch_in() { echo $(( $(date +%s) + $1 )); }

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

# 2) an isolated HOME with a generic Claude account (the account + plan segments
#    read ~/.claude.json; never let the demo show the real one)
export HOME="$DEMO/home"; mkdir -p "$HOME"
cat > "$HOME/.claude.json" <<'EOF'
{"oauthAccount":{"emailAddress":"alice@example.com","billingType":"stripe_subscription","organizationRateLimitTier":"default_claude_max_20x"}}
EOF

# 3) seeded caches (generic) under an isolated XDG home
mkdir -p "$DEMO/cache/cctreeline" "$DEMO/config/cctreeline"
mkdir -p "$DEMO/wt-feature-auth/src" "$DEMO/wt-hotfix-payments/src"
now=$(( $(date +%s) * 1000 ))
# worktree cache is per repository: worktrees-<basename>-<cksum of main repo path>.json
WT_CACHE="$DEMO/cache/cctreeline/worktrees-myapp-$(printf '%s' "$repo" | cksum | awk '{print $1}').json"
cat > "$WT_CACHE" <<EOF
{"worktrees":[
 {"name":"myapp-feature-auth","slug":"feature-auth","branch":"feature-auth","path":"$DEMO/wt-feature-auth","prs":[142]},
 {"name":"myapp-hotfix-payments","slug":"hotfix-payments","branch":"hotfix-payments","path":"$DEMO/wt-hotfix-payments","prs":[143,144]}
],"timestamp":$now}
EOF
cat > "$DEMO/config/cctreeline/config" <<EOF
CCTREELINE_USAGE_GAUGES=0   # Claude Code 2.1+ sends rate_limits on stdin; no credentials needed
CCTREELINE_WORKTREE_LINE=1
CCTREELINE_COLOR=256
CCTREELINE_GLYPHS=unicode
CCTREELINE_DENSITY=full
CCTREELINE_REUSE_HUD_CACHE=0
EOF

# 4) transcript: edits in BOTH worktrees this session (drives line 3)
cat > "$DEMO/transcript.jsonl" <<EOF
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"$DEMO/wt-feature-auth/src/login.ts"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"$DEMO/wt-hotfix-payments/src/charge.ts"}}]}}
EOF

# 5) the JSON Claude Code 2.1+ feeds the statusline on stdin (generic values)
STDIN=$(jq -n --arg cwd "$repo" --arg tp "$DEMO/transcript.jsonl" \
  --argjson r5 "$(epoch_in 11520)" --argjson r7 "$(epoch_in 183600)" --argjson pc "$(epoch_in 2400)" '{
  workspace:{current_dir:$cwd}, transcript_path:$tp, session_id:"a1b2c3d4-e5f67890",
  session_name:"auth-refactor",
  model:{id:"claude-opus-5-5", display_name:"Opus 5.5"}, output_style:{name:"default"},
  effort:{level:"high"}, thinking:{enabled:true},
  cost:{total_duration_ms:740000, total_cost_usd:3.12},
  prompt_cache:{warm:true, expires_at:$pc},
  context_window:{context_window_size:1000000, used_percentage:31},
  rate_limits:{five_hour:{used_percentage:42, resets_at:$r5}, seven_day:{used_percentage:58, resets_at:$r7}}}')

printf '\n'
printf '  \033[2m# the statusline Claude Code renders below your prompt:\033[0m\n\n'
echo "$STDIN" | XDG_CACHE_HOME="$DEMO/cache" XDG_CONFIG_HOME="$DEMO/config" bash "$ROOT/cctreeline.sh" | sed 's/^/  /'
printf '\n'
