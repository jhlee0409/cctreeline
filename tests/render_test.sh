#!/usr/bin/env bash
# Render-mode tests against recorded / documented Claude Code statusLine payloads.
# Expected values come from the payloads themselves (what Claude Code reports),
# not from cctreeline's output.
#   bash tests/render_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../cctreeline.sh"

# isolate from the real machine: no real caches, config, or credentials
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/config" XDG_CACHE_HOME="$sandbox/cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/cctreeline"
# usage-API fallback off: anything shown on line 2 must come from stdin
printf 'CCTREELINE_USAGE_GAUGES=0\nCCTREELINE_COLOR=none\n' > "$XDG_CONFIG_HOME/cctreeline/config"

fail=0
check() { # name, haystack, needle
  if grep -qF -- "$3" <<<"$2"; then echo "ok   - $1"
  else echo "FAIL - $1: expected '$3' in:"; sed 's/^/       /' <<<"$2"; fail=1; fi
}
check_not() {
  if grep -qF -- "$3" <<<"$2"; then echo "FAIL - $1: did not expect '$3' in:"; sed 's/^/       /' <<<"$2"; fail=1
  else echo "ok   - $1"; fi
}

# 1. recorded payload, Claude Code 2.1.332, Opus 5.5 on a 1M window
out=$(bash "$script" < "$here/fixtures/cc-2.1.332-opus1m.json")
check "1M window: ctx uses context_window.used_percentage (8%)" "$out" "ctx ░░░░░░░░░░ 8%"
check "1M window: badge from context_window_size"               "$out" "Opus 5.5 1M"
check "seven_day from stdin rate_limits (82%)"                   "$out" "7d ████████░░ 82%"
check_not "five_hour absent in payload -> no 5h segment"         "$out" "5h-"

# 2. documented example payload, 200k window, both windows present
out=$(bash "$script" < "$here/fixtures/docs-example-200k.json")
check "200k window: ctx 8%"                                      "$out" "ctx ░░░░░░░░░░ 8%"
check_not "200k window: no 1M badge"                             "$out" "1M"
check "five_hour 23.5 -> 24% (rounded)"                          "$out" "5h-24%"
check "seven_day 41.2 -> 41%"                                    "$out" "7d ████░░░░░░ 41%"

# 3. early session: used_percentage null, no rate_limits -> no fake numbers
out=$(jq '.context_window.used_percentage=null | .context_window.current_usage=null | del(.rate_limits)' \
        "$here/fixtures/docs-example-200k.json" | bash "$script")
check_not "null used_percentage -> no ctx number"                "$out" "ctx ░░░░░░░░░░ 0%"
check_not "no rate_limits -> no 7d"                              "$out" "7d"
check_not "no rate_limits -> no 5h"                              "$out" "5h-"

# 4. countdown from epoch-seconds resets_at (5h window resets in 2h, 7d in 3 days)
now=$(date +%s)
out=$(jq --argjson f "$((now + 7200 + 30))" --argjson w "$((now + 3*86400 + 30))" \
        '.rate_limits.five_hour.resets_at=$f | .rate_limits.seven_day.resets_at=$w' \
        "$here/fixtures/docs-example-200k.json" | bash "$script")
check "5h countdown from resets_at epoch seconds"                "$out" "5h-24% 2h"
check "7d countdown from resets_at epoch seconds"                "$out" "41% 3d"

# 5. installed-copy features, on the recorded payload
out=$(bash "$script" < "$here/fixtures/cc-2.1.332-opus1m.json")
check "effort level on line 1 (effort.level=medium)"             "$out" "Opus 5.5 1M medium"
check "session_name + short id (session_name=fixture)"           "$out" "fixture 23203d9b"
check "prompt cache past expires_at -> cold"                     "$out" "cache cold"
check "session cost 1.0078 -> \$1.01"                            "$out" '$1.01'
check_not "no ~/.claude.json -> no plan tag"                     "$out" "Max20x"

# 6. signed-in account + plan, from a Claude Code style ~/.claude.json
cat > "$HOME/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"alice@example.com","displayName":"Alice Kim",
 "organizationName":"Example Inc","billingType":"stripe_subscription",
 "organizationRateLimitTier":"default_claude_max_20x"}}
JSON
out=$(bash "$script" < "$here/fixtures/cc-2.1.332-opus1m.json")
check "account label = email local-part"                         "$out" "@alice"
check_not "full email not shown by default"                      "$out" "alice@example.com"
check "plan tag from max_20x tier in front of cost"              "$out" 'Max20x·$1.01'
printf 'CCTREELINE_ACCOUNT=org\nCCTREELINE_PLAN=Ultra\n' >> "$XDG_CONFIG_HOME/cctreeline/config"
out=$(bash "$script" < "$here/fixtures/cc-2.1.332-opus1m.json")
check "CCTREELINE_ACCOUNT=org"                                   "$out" "@Example Inc"
check "CCTREELINE_PLAN override"                                 "$out" 'Ultra·$1.01'
printf 'CCTREELINE_USAGE_GAUGES=0\nCCTREELINE_COLOR=none\n' > "$XDG_CONFIG_HOME/cctreeline/config"
jq '.oauthAccount.billingType="api"' "$HOME/.claude.json" > "$HOME/.claude.json.t" && mv "$HOME/.claude.json.t" "$HOME/.claude.json"
out=$(bash "$script" < "$here/fixtures/cc-2.1.332-opus1m.json")
check_not "API billing -> dollars are literal, no plan tag"      "$out" "Max20x"
rm -f "$HOME/.claude.json"

# 7. compactions + line 3, in a real repo with two linked worktrees
repo="$sandbox/myapp"; mkdir -p "$repo"
git -C "$repo" init -q; git -C "$repo" symbolic-ref HEAD refs/heads/main
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$repo" worktree add -q -b feature-auth "$sandbox/myapp-feature-auth"
git -C "$repo" worktree add -q -b hotfix-pay "$sandbox/myapp-hotfix-pay"
repo=$(cd "$repo" && pwd -P); wt1=$(cd "$sandbox/myapp-feature-auth" && pwd -P); wt2=$(cd "$sandbox/myapp-hotfix-pay" && pwd -P)
# seed the per-repository worktree cache (fresh, so no background gh call)
key=$(printf '%s' "$repo" | cksum | awk '{print $1}')
mkdir -p "$XDG_CACHE_HOME/cctreeline"
jq -n --arg a "$wt1" --arg b "$wt2" --argjson ts "$(( $(date +%s) * 1000 ))" '{worktrees:[
  {name:"myapp-feature-auth",slug:"feature-auth",branch:"feature-auth",path:$a,prs:[142]},
  {name:"myapp-hotfix-pay",slug:"hotfix-pay",branch:"hotfix-pay",path:$b,prs:[]}],timestamp:$ts}' \
  > "$XDG_CACHE_HOME/cctreeline/worktrees-myapp-$key.json"
tr="$sandbox/transcript.jsonl"
jq -nc '{type:"system",subtype:"compact_boundary"}' > "$tr"
jq -nc '{type:"system",subtype:"compact_boundary"}' >> "$tr"
jq -nc --arg p "$wt1/src/login.ts" '{type:"assistant",message:{content:[{type:"tool_use",name:"Edit",input:{file_path:$p}}]}}' >> "$tr"
payload=$(jq --arg cwd "$repo" --arg tr "$tr" '.cwd=$cwd | .workspace.current_dir=$cwd | .transcript_path=$tr' \
            "$here/fixtures/docs-example-200k.json")
out=$(bash "$script" <<<"$payload")
check "two compact_boundary records -> cmp 2"                    "$out" "cmp 2"
check "edited worktree listed with its PR"                       "$out" "⎇ feature-auth PR: #142"
check_not "untouched worktree not listed"                        "$out" "hotfix-pay"
jq -nc --arg c "cd $wt2 && npm test" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}' >> "$tr"
out=$(bash "$script" <<<"$payload")
check "worktree used only via a Bash command is listed"          "$out" "⎇ hotfix-pay PR: —"

exit $fail
