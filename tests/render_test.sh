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

exit $fail
