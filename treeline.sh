#!/usr/bin/env bash
# treeline — a Claude Code statusline for people who run multiple git worktrees.
#
# Three lines:
#   1. duration · path · branch + worktree badge + dirty marks · model · session id
#   2. ctx gauge │ weekly (auto-binding, per-model scope) │ 5h rolling
#   3. per-worktree open-PR overview, scoped to the worktrees you edited THIS session
#
# Pure bash + jq. No node in the render hot path, no `npx @latest` on every frame.
# Cross-platform: auto-detects GNU/BSD date+stat and the platform credential store.
#
# Usage (Claude Code settings.json):
#   { "statusLine": { "type": "command", "command": "bash /path/to/treeline.sh" } }
#
# Subcommands (used internally for async cache refresh; you don't call these):
#   treeline.sh --refresh-usage          refresh the 5h/weekly usage cache
#   treeline.sh --refresh-worktrees CWD  refresh the worktree+PR cache
#
# Config: ${XDG_CONFIG_HOME:-~/.config}/treeline/config  (written by install.sh)

set -o pipefail

# ── resolve self path (for async self-invocation) ───────────────
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
[ -f "$SELF" ] || SELF="$0"

# ── XDG paths ───────────────────────────────────────────────────
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/treeline"
CONFIG_FILE="$CONFIG_DIR/config"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/treeline"
USAGE_CACHE="$CACHE_DIR/usage.json"
WT_CACHE="$CACHE_DIR/worktrees.json"
mkdir -p "$CACHE_DIR" 2>/dev/null

# ── config defaults (overridden by CONFIG_FILE) ─────────────────
TREELINE_USAGE_GAUGES=1       # read Claude creds + show 5h/weekly gauges
TREELINE_WORKTREE_LINE=auto   # line 3 worktree-PR view: 1 | 0 | auto
TREELINE_COLOR=auto           # auto | 256 | none
TREELINE_GLYPHS=unicode       # unicode | ascii
TREELINE_DENSITY=full         # full | compact
TREELINE_REUSE_HUD_CACHE=auto # reuse claude-hud's usage cache if present
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# ── platform detection (never asked — always auto) ──────────────
case "$(uname -s)" in Darwin) IS_MAC=1 ;; *) IS_MAC=0 ;; esac
if date --version >/dev/null 2>&1; then GNU_DATE=1; else GNU_DATE=0; fi

_epoch_now() { date +%s; }

# parse an RFC3339 / ISO8601 timestamp to epoch seconds. Handles a trailing
# Z, a numeric ±HH:MM offset, fractional seconds, or a bare (UTC-assumed) time.
_epoch_from_iso() {
  local iso="$1"
  if [ "$GNU_DATE" = "1" ]; then
    case "$iso" in
      # zoned (Z or ±HH:MM) — GNU date honors it directly
      *T*[Zz]|*T*[+-][0-9][0-9]:[0-9][0-9]) date -u -d "$iso" +%s 2>/dev/null || echo 0 ;;
      # zoneless — force UTC so the epoch doesn't shift by the local offset
      *) date -u -d "${iso/T/ } UTC" +%s 2>/dev/null || echo 0 ;;
    esac
  else
    # BSD date can't parse zone designators; strip fractional, Z, and offset,
    # then parse as UTC (resets_at is UTC in practice).
    iso="${iso%.*}"; iso="${iso%[Zz]}"; iso="${iso%[+-][0-9][0-9]:[0-9][0-9]}"
    date -j -u -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null || echo 0
  fi
}

# file modification time as epoch seconds
_file_mtime() {
  if [ "$GNU_DATE" = "1" ]; then stat -c %Y "$1" 2>/dev/null || echo 0
  else stat -f %m "$1" 2>/dev/null || echo 0; fi
}

# read Claude Code OAuth credentials JSON, platform-agnostic
_read_credentials() {
  if [ "$IS_MAC" = "1" ] && command -v security >/dev/null 2>&1; then
    /usr/bin/security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null && return 0
  fi
  local f
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" "$HOME/.claude/.credentials.json"; do
    [ -f "$f" ] && { cat "$f"; return 0; }
  done
  return 1
}

# ════════════════════════════════════════════════════════════════
# SUBCOMMAND: --refresh-usage  (5h + weekly limits via OAuth usage API)
# ════════════════════════════════════════════════════════════════
refresh_usage() {
  local cache="$USAGE_CACHE" lock="$CACHE_DIR/usage.lock"
  # atomic single-flight: noclobber create wins the lock; otherwise honor an
  # existing lock unless it's stale (>30s), then take it over.
  if ( set -o noclobber; echo $$ > "$lock" ) 2>/dev/null; then :
  else
    local age=$(( $(_epoch_now) - $(_file_mtime "$lock") ))
    [ "$age" -lt 30 ] && return 0
    echo $$ > "$lock"
  fi
  # tmp inside CACHE_DIR so the final mv is a same-filesystem atomic rename
  local tmp; tmp=$(mktemp "$CACHE_DIR/usage.XXXXXX") || { rm -f "$lock"; return 0; }
  trap 'rm -f "$tmp" "$lock"' EXIT

  local creds token sub
  creds=$(_read_credentials) || return 0
  token=$(jq -r '.claudeAiOauth.accessToken // empty' <<<"$creds" 2>/dev/null)
  sub=$(jq -r '.claudeAiOauth.subscriptionType // empty' <<<"$creds" 2>/dev/null)
  [ -z "$token" ] && return 0

  local plan="Max"
  case "$sub" in *[Mm]ax*) plan="Max";; *[Pp]ro*) plan="Pro";; *[Tt]eam*) plan="Team";; esac

  # Pass the bearer token via a curl config on stdin (-K -) so the secret never
  # appears in the process argument list (ps-readable). CWE-214.
  local resp
  resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS --max-time 5 -K - \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: treeline/0.1" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 0
  [ -z "$resp" ] && return 0

  local five_h seven_d five_reset seven_reset
  five_h=$(jq -r '.five_hour.utilization // empty' <<<"$resp")
  seven_d=$(jq -r '.seven_day.utilization // empty' <<<"$resp")
  five_reset=$(jq -r '.five_hour.resets_at // empty' <<<"$resp")
  seven_reset=$(jq -r '.seven_day.resets_at // empty' <<<"$resp")
  [ -z "$five_h" ] && return 0

  # 2026+ usage API may expose a limits[] array with per-model weekly buckets.
  # Pick the binding weekly limit the way /status highlights it: prefer the
  # is_active weekly entry, else the highest-utilization weekly. Falls back to
  # the flat seven_day when limits[] is absent (older accounts / most regions).
  local binding week_pct week_reset week_scope
  binding=$(jq -c '
    if (.limits | type) == "array" then
      ([.limits[] | select(.group=="weekly" and (.percent != null))] as $w
       | (($w | map(select(.is_active==true)) | .[0]) // ($w | max_by(.percent))))
    else null end' <<<"$resp")
  if [ -n "$binding" ] && [ "$binding" != "null" ]; then
    week_pct=$(jq -r '.percent // empty' <<<"$binding")
    week_reset=$(jq -r '.resets_at // empty' <<<"$binding")
    week_scope=$(jq -r '.scope.model.display_name // "all"' <<<"$binding")
  else
    week_pct="$seven_d"; week_reset="$seven_reset"; week_scope="all"
  fi

  # coerce to numeric so a malformed API value can't make jq -n fail
  [[ "$five_h"   =~ ^[0-9]+(\.[0-9]+)?$ ]] || five_h=0
  [[ "$week_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || week_pct=0

  jq -n \
    --arg plan "$plan" --argjson fh "${five_h:-0}" \
    --arg fr "$five_reset" --argjson wp "${week_pct:-0}" \
    --arg wsc "$week_scope" --arg wr "$week_reset" \
    --argjson ts "$(($(_epoch_now) * 1000))" \
    '{data:{planName:$plan, fiveHour:$fh, fiveHourResetAt:$fr,
            weeklyBindingPct:$wp, weeklyBindingScope:$wsc, weeklyBindingResetAt:$wr},
      timestamp:$ts}' > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$cache" || rm -f "$tmp"
}

# ════════════════════════════════════════════════════════════════
# SUBCOMMAND: --refresh-worktrees CWD  (worktree list + open PRs)
# ════════════════════════════════════════════════════════════════
refresh_worktrees() {
  local cwd="${1:-$PWD}" cache="$WT_CACHE" lock="$CACHE_DIR/worktrees.lock"
  if ( set -o noclobber; echo $$ > "$lock" ) 2>/dev/null; then :
  else
    local age=$(( $(_epoch_now) - $(_file_mtime "$lock") ))
    [ "$age" -lt 60 ] && return 0
    echo $$ > "$lock"
  fi
  local tmp; tmp=$(mktemp "$CACHE_DIR/wt.XXXXXX") || { rm -f "$lock"; return 0; }
  trap 'rm -f "$tmp" "$lock"' EXIT

  local common_dir abs_common_dir main_repo main_basename
  common_dir=$(git -C "$cwd" --no-optional-locks rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$common_dir" in
    /*) abs_common_dir="$common_dir" ;;
    *)  abs_common_dir="$(cd "$cwd" && cd "$common_dir" 2>/dev/null && pwd)" || return 0 ;;
  esac
  main_repo=$(cd "$abs_common_dir/.." 2>/dev/null && pwd) || return 0
  main_basename=$(basename "$main_repo")

  local wt_data; wt_data=$(git -C "$main_repo" --no-optional-locks worktree list --porcelain 2>/dev/null) || return 0

  local has_gh=0; command -v gh >/dev/null 2>&1 && has_gh=1
  local entries=() cur_path="" cur_branch=""
  flush() {
    if [ -n "$cur_path" ] && [ -n "$cur_branch" ] && [ "$cur_path" != "$main_repo" ]; then
      entries+=("$cur_path|$cur_branch")
    fi
    cur_path=""; cur_branch=""
  }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) flush; cur_path="${line#worktree }" ;;
      "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
      "") flush ;;
    esac
  done <<<"$wt_data"
  flush

  local worktrees_json="[]" entry path branch name slug prs pr_nums
  for entry in "${entries[@]}"; do
    path="${entry%%|*}"; branch="${entry#*|}"
    name=$(basename "$path"); slug="${name#"${main_basename}"-}"
    if [ "$has_gh" = "1" ]; then
      prs=$(cd "$path" 2>/dev/null && timeout 5 gh pr list --head "$branch" --state open --json number 2>/dev/null || echo '[]')
    else prs='[]'; fi
    [ -z "$prs" ] && prs='[]'
    pr_nums=$(jq -c '[.[].number]' <<<"$prs" 2>/dev/null || echo '[]')
    worktrees_json=$(jq -c \
      --arg name "$name" --arg slug "$slug" --arg branch "$branch" \
      --arg path "$path" --argjson prs "$pr_nums" \
      '. + [{name:$name, slug:$slug, branch:$branch, path:$path, prs:$prs}]' <<<"$worktrees_json")
  done

  jq -n --argjson wts "$worktrees_json" --argjson ts "$(($(_epoch_now) * 1000))" \
    '{worktrees:$wts, timestamp:$ts}' > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$cache" || rm -f "$tmp"
}

# ── dispatch subcommands ────────────────────────────────────────
case "${1:-}" in
  --refresh-usage)      refresh_usage; exit 0 ;;
  --refresh-worktrees)  refresh_worktrees "${2:-}"; exit 0 ;;
esac

# ════════════════════════════════════════════════════════════════
# RENDER MODE (default) — reads the statusLine JSON on stdin
# ════════════════════════════════════════════════════════════════
input=$(cat)

# ── color setup ─────────────────────────────────────────────────
COLOR_ON=1
case "$TREELINE_COLOR" in
  none) COLOR_ON=0 ;;
  256)  COLOR_ON=1 ;;
  auto|*)
    [ -n "${NO_COLOR:-}" ] && COLOR_ON=0
    [ "${TERM:-}" = "dumb" ] && COLOR_ON=0
    ;;
esac
c()   { [ "$COLOR_ON" = "1" ] && printf '\033[38;5;%sm' "$1"; }
bld() { [ "$COLOR_ON" = "1" ] && printf '\033[1m'; }
rst() { [ "$COLOR_ON" = "1" ] && printf '\033[0m'; }

# ── glyph setup ─────────────────────────────────────────────────
if [ "$TREELINE_GLYPHS" = "ascii" ]; then
  G_FILL="#"; G_EMPTY="."; G_MAIN="="; G_MOD="*"; G_AHEAD="^"
  G_CLEAN="ok"; G_SEP="|"; G_ELLIP="..."; G_WT="wt"
else
  G_FILL="█"; G_EMPTY="░"; G_MAIN="⌂"; G_MOD="●"; G_AHEAD="↑"
  G_CLEAN="✓"; G_SEP="·"; G_ELLIP="…"; G_WT="⎇"
fi

# Identity colors — each metric a consistent hue
PATH_C=75; GIT_C=205; MODEL_C=220
CTX_C=39; RATE_C=208; WEEK_C=141
ADD_C=82; DUR_C=244; DIM_C=240; WARN_C=196

# 10-char gauge: 1 cell = 10%
gauge() {
  local pct=$1 col=$2 filled=$(( $1 / 10 )) out="" i
  (( filled > 10 )) && filled=10; (( filled < 0 )) && filled=0
  out+="$(c "$col")"; for ((i=0;i<filled;i++)); do out+="$G_FILL"; done
  out+="$(c $DIM_C)"; for ((i=filled;i<10;i++)); do out+="$G_EMPTY"; done
  out+="$(rst)"; printf '%s' "$out"
}
pct_text() {
  local pct=$1 col=${2:-$DIM_C}
  if   (( pct >= 80 )); then printf '%s%d%%%s' "$(c $WARN_C)$(bld)" "$pct" "$(rst)"
  elif (( pct >= 60 )); then printf '%s%d%%%s' "$(c 214)" "$pct" "$(rst)"
  else printf '%s%d%%%s' "$(c "$col")" "$pct" "$(rst)"; fi
}
majsep="$(c $DIM_C)${G_SEP}$(rst)"

# ── extract fields ──────────────────────────────────────────────
cwd=$(jq -r '.workspace.current_dir // .cwd // ""' <<<"$input")
transcript_path=$(jq -r '.transcript_path // ""' <<<"$input")
session_id=$(jq -r '.session_id // ""' <<<"$input")
model=$(jq -r '.model.display_name // ""' <<<"$input")
model_id=$(jq -r '.model.id // ""' <<<"$input")
output_style=$(jq -r '.output_style.name // ""' <<<"$input")
duration_ms=$(jq -r '.cost.total_duration_ms // empty' <<<"$input")
exceeds_200k=$(jq -r '.exceeds_200k_tokens // false' <<<"$input")

# ── path (repo-relative, middle-ellipsis) ───────────────────────
# collapse $HOME to ~ only on a path boundary (so /Users/jackson ≠ ~son)
case "$cwd" in
  "$HOME")   short_cwd="~" ;;
  "$HOME"/*) short_cwd="~${cwd#"$HOME"}" ;;
  *)         short_cwd="$cwd" ;;
esac
git_top=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
if [ -n "$git_top" ]; then
  repo_name=$(basename "$git_top"); rel="${cwd#"$git_top"}"; rel="${rel#/}"
  if [ -n "$rel" ]; then short_cwd="$repo_name/$rel"; else short_cwd="$repo_name"; fi
fi
if [ ${#short_cwd} -gt 38 ]; then
  IFS='/' read -ra parts <<<"$short_cwd"; n=${#parts[@]}
  (( n > 3 )) && short_cwd="${parts[0]}/${G_ELLIP}/${parts[n-2]}/${parts[n-1]}"
fi

# ── git: branch, worktree badge, dirty marks ────────────────────
branch_disp=""; git_marks=""; wt_marker=""
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  git_dir=$(git -C "$cwd" --no-optional-locks rev-parse --git-dir 2>/dev/null)
  common_dir=$(git -C "$cwd" --no-optional-locks rev-parse --git-common-dir 2>/dev/null)
  if [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]; then
    parent_repo=""
    if [ -n "$common_dir" ]; then
      parent_top=$(cd "$cwd" 2>/dev/null && cd "$common_dir/.." 2>/dev/null && pwd)
      [ -n "$parent_top" ] && parent_repo=$(basename "$parent_top")
    fi
    if [ -n "$parent_repo" ] && [ -n "$repo_name" ] && [[ "$repo_name" != "$parent_repo"* ]]; then
      wt_marker=" $(bld)$(c 141)${G_WT}wt($parent_repo)$(rst)"
    else
      wt_marker=" $(bld)$(c 141)${G_WT}wt$(rst)"
    fi
  else
    wt_marker=" $(c $DIM_C)${G_MAIN}main$(rst)"
  fi
  if [ -n "$branch" ]; then
    porcelain=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
    if [ -n "$porcelain" ]; then
      mod=$(printf '%s\n' "$porcelain" | grep -c '^.M' || true)
      sta=$(printf '%s\n' "$porcelain" | grep -c '^[MARC]' || true)
      [ "$mod" -gt 0 ] 2>/dev/null && git_marks+=" $(c 214)${G_MOD}$mod$(rst)"
      [ "$sta" -gt 0 ] 2>/dev/null && git_marks+=" $(c $ADD_C)+$sta$(rst)"
    else
      git_marks=" $(c $ADD_C)${G_CLEAN}$(rst)"
    fi
    upstream=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref '@{u}' 2>/dev/null)
    if [ -n "$upstream" ]; then
      ab=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count "HEAD...@{u}" 2>/dev/null)
      ahead=$(awk '{print $1}' <<<"$ab")
      [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null && git_marks+=" $(c $MODEL_C)${G_AHEAD}$ahead$(rst)"
    fi
    if [ ${#branch} -gt 26 ]; then branch_disp="${branch:0:25}${G_ELLIP}"; else branch_disp="$branch"; fi
  fi
fi

# ── model short label + 1M badge ────────────────────────────────
model_short="$model"
case "$model" in *Opus*) model_short="Opus";; *Sonnet*) model_short="Sonnet";; *Haiku*) model_short="Haiku";; esac
ver_num=$(grep -oE '[0-9]+\.[0-9]+' <<<"$model" | head -1)
[ -n "$ver_num" ] && model_short="$model_short $ver_num"
is_1m=0
if [[ "$model" == *"1M"* ]] || [[ "$model_id" == *"1m"* ]] || [ "$exceeds_200k" = "true" ]; then
  is_1m=1; model_short="$model_short $(c $WEEK_C)1M$(c $MODEL_C)"
fi

# ── ctx % from transcript usage ─────────────────────────────────
ctx_pct=""; unknown_ctx=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  unknown_ctx=1; usage_json=""
  for nn in 500 2000; do
    usage_json=$(tail -n "$nn" "$transcript_path" 2>/dev/null \
      | jq -c 'select(.type=="assistant" and (.message.usage // false)) | .message.usage' 2>/dev/null | tail -n 1)
    [ -n "$usage_json" ] && break
  done
  [ -z "$usage_json" ] && usage_json=$(jq -c 'select(.type=="assistant" and (.message.usage // false)) | .message.usage' "$transcript_path" 2>/dev/null | tail -n 1)
  if [ -n "$usage_json" ]; then
    unknown_ctx=0
    in_tok=$(jq -r '.input_tokens // 0' <<<"$usage_json")
    cr_tok=$(jq -r '.cache_read_input_tokens // 0' <<<"$usage_json")
    cc_tok=$(jq -r '.cache_creation_input_tokens // 0' <<<"$usage_json")
    # never feed transcript-derived values into $(( )) unvalidated
    for _v in in_tok cr_tok cc_tok; do [[ ${!_v} =~ ^[0-9]+$ ]] || printf -v "$_v" 0; done
    used=$(( in_tok + cr_tok + cc_tok ))
    if (( is_1m )); then max=1000000; else max=200000; fi
    ctx_pct=$(( used * 100 / max )); (( ctx_pct > 100 )) && ctx_pct=100
  fi
fi

# ── 5h / weekly from usage cache (optional, consent-gated) ──────
block_pct=""; block_remain=""; week_pct=""; week_remain=""; week_scope="all"
if [ "$TREELINE_USAGE_GAUGES" = "1" ]; then
  # prefer treeline's own cache; optionally reuse claude-hud's if present
  hud_cache="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/claude-hud/.usage-cache.json"
  active_cache="$USAGE_CACHE"
  if [ "$TREELINE_REUSE_HUD_CACHE" != "0" ] && [ -f "$hud_cache" ]; then
    [ ! -f "$USAGE_CACHE" ] && active_cache="$hud_cache"
    [ -f "$USAGE_CACHE" ] && [ "$(_file_mtime "$hud_cache")" -gt "$(_file_mtime "$USAGE_CACHE")" ] && active_cache="$hud_cache"
  fi
  # async refresh if our cache is stale (>60s)
  needs_refresh=1
  if [ -f "$USAGE_CACHE" ]; then
    ts=$(jq -r '.timestamp // 0' "$USAGE_CACHE" 2>/dev/null)
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0   # empty/malformed cache must not break $(( ))
    age=$(( $(_epoch_now) - ts/1000 ))
    [ "$age" -lt 60 ] && needs_refresh=0
  fi
  if [ "$needs_refresh" = "1" ]; then
    nohup bash "$SELF" --refresh-usage >/dev/null 2>&1 & disown 2>/dev/null || true
  fi
  if [ -f "$active_cache" ] && jq empty "$active_cache" 2>/dev/null; then
    block_pct=$(jq -r '.data.fiveHour // empty' "$active_cache")
    week_pct=$(jq -r '.data.weeklyBindingPct // .data.sevenDay // empty' "$active_cache")
    week_scope=$(jq -r '.data.weeklyBindingScope // "all"' "$active_cache")
    five_reset=$(jq -r '.data.fiveHourResetAt // empty' "$active_cache")
    week_reset=$(jq -r '.data.weeklyBindingResetAt // .data.sevenDayResetAt // empty' "$active_cache")
    now_s=$(_epoch_now)
    if [ -n "$five_reset" ]; then
      diff=$(( $(_epoch_from_iso "$five_reset") - now_s ))
      if (( diff > 0 )); then
        if (( diff >= 3600 )); then h=$((diff/3600)); m=$(((diff%3600)/60)); block_remain="${h}h"; (( m>0 )) && block_remain="${h}h${m}m"
        else block_remain="$((diff/60))m"; fi
      fi
    fi
    if [ -n "$week_reset" ]; then
      diff=$(( $(_epoch_from_iso "$week_reset") - now_s ))
      if (( diff > 0 )); then
        if (( diff >= 86400 )); then d=$((diff/86400)); h=$(((diff%86400)/3600)); week_remain="${d}d"; (( h>0 )) && week_remain="${d}d${h}h"
        elif (( diff >= 3600 )); then h=$((diff/3600)); m=$(((diff%3600)/60)); week_remain="${h}h"; (( m>0 )) && week_remain="${h}h${m}m"
        else week_remain="$((diff/60))m"; fi
      fi
    fi
  fi
fi

# ── session duration ────────────────────────────────────────────
dur_disp=""
if [ -n "$duration_ms" ] && [ "$duration_ms" -gt 0 ] 2>/dev/null; then
  s=$(( duration_ms / 1000 ))
  if   (( s < 60 )); then ds="${s}s"
  elif (( s < 3600 )); then ds="$((s/60))m"
  else ds="$((s/3600))h$(((s%3600)/60))m"; fi
  dur_disp="$(c $DUR_C)${ds}$(rst)"
fi

# ── compose line 1 ──────────────────────────────────────────────
line1=""
[ -n "$dur_disp" ] && line1+="${dur_disp} $majsep "
line1+="$(bld)$(c $PATH_C)${short_cwd}$(rst)"
[ -n "$branch_disp" ] && line1+=" $majsep $(c $GIT_C)${branch_disp}$(rst)${wt_marker}${git_marks}"
[ -n "$model_short" ] && line1+=" $majsep $(bld)$(c $MODEL_C)${model_short}$(rst)"
sess_id="$session_id"
[ -z "$sess_id" ] && [ -n "$transcript_path" ] && sess_id=$(basename "$transcript_path" .jsonl)
[ -n "$sess_id" ] && line1+=" $majsep $(c $DIM_C)id:${sess_id:0:15}$(rst)"

# ── compose line 2 ──────────────────────────────────────────────
parts=()
if [ -n "$ctx_pct" ]; then
  parts+=("$(c $CTX_C)ctx$(rst) $(gauge "$ctx_pct" "$CTX_C") $(pct_text "$ctx_pct" $CTX_C)")
elif (( unknown_ctx )); then
  parts+=("$(c $CTX_C)ctx$(rst) $(c $DIM_C)──────────$(rst) $(c $DIM_C)?$(rst)")
fi
if [ "$TREELINE_DENSITY" = "full" ] && [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
  parts+=("$(c $WEEK_C)${output_style}$(rst)")
fi
if [ "$TREELINE_DENSITY" = "full" ] && [ -n "$week_pct" ]; then
  wp_int=$(awk -v v="$week_pct" 'BEGIN{printf "%d", v+0.5}')
  if [ -n "$week_scope" ] && [ "$week_scope" != "all" ] && [ "$week_scope" != "null" ]; then
    week_lbl="$(c $WEEK_C)7d·${week_scope}$(rst)"; else week_lbl="$(c $WEEK_C)7d$(rst)"; fi
  week_meta=""; [ -n "$week_remain" ] && week_meta=" $(c $WEEK_C)${week_remain}$(rst)"
  parts+=("$week_lbl $(gauge "$wp_int" "$WEEK_C") $(pct_text "$wp_int" $WEEK_C)$week_meta")
fi
if [ -n "$block_pct" ]; then
  bp_int=$(awk -v v="$block_pct" 'BEGIN{printf "%d", v+0.5}')
  rate_meta=""; [ -n "$block_remain" ] && rate_meta=" $(c $RATE_C)${block_remain}$(rst)"
  parts+=("$(c $RATE_C)5h-$(rst)$(pct_text "$bp_int" $RATE_C)$rate_meta")
fi
line2=""
if [ ${#parts[@]} -gt 0 ]; then
  line2="${parts[0]}"; for ((i=1;i<${#parts[@]};i++)); do line2+=" $majsep ${parts[i]}"; done
fi

# ── compose line 3: worktree PRs, scoped to this session's edits ─
line3=""
wt_enabled=0
case "$TREELINE_WORKTREE_LINE" in
  1) wt_enabled=1 ;;
  0) wt_enabled=0 ;;
  auto) [ -n "$git_top" ] && wt_enabled=1 ;;
esac
if [ "$wt_enabled" = "1" ] && [ -n "$git_top" ]; then
  # async refresh worktree cache if stale (>120s)
  wt_needs=1
  if [ -f "$WT_CACHE" ]; then
    ts=$(jq -r '.timestamp // 0' "$WT_CACHE" 2>/dev/null)
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    age=$(( $(_epoch_now) - ts/1000 ))
    [ "$age" -lt 120 ] && wt_needs=0
  fi
  [ "$wt_needs" = "1" ] && { nohup bash "$SELF" --refresh-worktrees "$cwd" >/dev/null 2>&1 & disown 2>/dev/null || true; }

  # edited file paths this session (Edit/Write/MultiEdit use file_path;
  # NotebookEdit uses notebook_path)
  edited=""
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    edited=$(jq -r '
      select(.type=="assistant") | .message.content[]?
      | select(.type=="tool_use")
      | select(.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
      | (.input.file_path // .input.notebook_path) // empty' "$transcript_path" 2>/dev/null | sort -u)
  fi
  if [ -f "$WT_CACHE" ] && [ -n "$edited" ]; then
    # canonicalize edited paths once (resolve symlinked prefixes; the file may
    # be gone after a delete, so resolve its directory and re-append basename)
    edited_real=""
    while IFS= read -r ep; do
      [ -z "$ep" ] && continue
      epd=$(cd "$(dirname "$ep")" 2>/dev/null && pwd -P) && edited_real+="$epd/$(basename "$ep")"$'\n' || edited_real+="$ep"$'\n'
    done <<<"$edited"
    items=()
    while IFS=$'\t' read -r name slug wpath prs_json; do
      [ -z "$slug" ] && continue
      # canonicalize the worktree path once, then match by path boundary
      wreal=$(cd "$wpath" 2>/dev/null && pwd -P) || wreal="$wpath"
      active=0
      while IFS= read -r ep; do
        [ -z "$ep" ] && continue
        case "$ep" in "$wreal"/*|"$wreal") active=1; break ;; esac
      done <<<"$edited_real"
      [ "$active" = "1" ] || continue
      pr_nums=""; has_pr=0
      while IFS= read -r num; do
        [ -z "$num" ] && continue; has_pr=1
        if [ -z "$pr_nums" ]; then pr_nums="$(c $MODEL_C)#${num}$(rst)"; else pr_nums+=" $(c $MODEL_C)#${num}$(rst)"; fi
      done < <(jq -r '.[]' <<<"$prs_json" 2>/dev/null)
      if (( has_pr )); then pr_strs=" $(c $RATE_C)PR:$(rst) ${pr_nums}"; else pr_strs=" $(c $DIM_C)PR:$(rst) $(c $DIM_C)—$(rst)"; fi
      items+=("$(c 141)${G_WT}$(rst) $(c $PATH_C)${slug}$(rst)${pr_strs}")
    done < <(jq -r '.worktrees[] | "\(.name)\t\(.slug)\t\(.path)\t\(.prs | tojson)"' "$WT_CACHE" 2>/dev/null)
    if [ ${#items[@]} -gt 0 ]; then
      line3="${items[0]}"; for ((i=1;i<${#items[@]};i++)); do line3+=$'\n'"${items[i]}"; done
    fi
  fi
fi

# ── output ──────────────────────────────────────────────────────
out="$line1"
[ -n "$line2" ] && out+=$'\n'"$line2"
[ -n "$line3" ] && out+=$'\n'"$line3"
printf '%s\n' "$out"
