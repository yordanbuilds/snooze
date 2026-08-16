#!/usr/bin/env bash
# CLI + helper tests. Everything runs unprivileged against a scratch hosts
# file via the helper's --hosts-file seam. Run: bash tests/scripts.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$HERE/bin/snooze-helper"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fails=0
check() { # <desc> <expected-exit> then runs "$@"
  local desc=$1 want=$2; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [[ $got -ne $want ]]; then
    echo "FAIL: $desc (exit $got, wanted $want)"; cat "$TMP/err"; fails=$((fails+1))
  else echo "ok: $desc"; fi
}

hosts() { printf '127.0.0.1 localhost\n::1 localhost\n' >"$TMP/hosts"; }

# --- helper: block writes the marked section, preserving existing content
hosts
check "block writes block" 0 "$HELPER" block --hosts-file "$TMP/hosts" 1755350400 x.com www.x.com
grep -q '^127.0.0.1 localhost$' "$TMP/hosts" || { echo "FAIL: lost localhost"; fails=$((fails+1)); }
grep -q '^# >>> snooze >>> until=1755350400$' "$TMP/hosts" || { echo "FAIL: no marker"; fails=$((fails+1)); }
grep -q '^0.0.0.0 x.com$' "$TMP/hosts" || { echo "FAIL: no entry"; fails=$((fails+1)); }

# --- re-block replaces, never duplicates or grows blank lines
check "re-block replaces" 0 "$HELPER" block --hosts-file "$TMP/hosts" 42 y.com
[[ $(grep -c '>>> snooze' "$TMP/hosts") -eq 1 ]] || { echo "FAIL: duplicate block"; fails=$((fails+1)); }
grep -q 'x.com' "$TMP/hosts" && { echo "FAIL: stale domain"; fails=$((fails+1)); }

# --- unblock removes the section and nothing else
check "unblock" 0 "$HELPER" unblock --hosts-file "$TMP/hosts"
grep -q 'snooze' "$TMP/hosts" && { echo "FAIL: markers left"; fails=$((fails+1)); }
grep -q '^127.0.0.1 localhost$' "$TMP/hosts" || { echo "FAIL: lost localhost"; fails=$((fails+1)); }

# --- validation
hosts
check "rejects invalid domain" 1 "$HELPER" block --hosts-file "$TMP/hosts" 0 "evil.com; rm -rf /"
check "rejects uppercase" 1 "$HELPER" block --hosts-file "$TMP/hosts" 0 "X.com"
check "rejects bad until" 1 "$HELPER" block --hosts-file "$TMP/hosts" tomorrow x.com
check "rejects no domains" 1 "$HELPER" block --hosts-file "$TMP/hosts" 0
mapfile -t many < <(seq 1 501 | sed 's/^/d/; s/$/.com/')
check "rejects >500 domains" 1 "$HELPER" block --hosts-file "$TMP/hosts" 0 "${many[@]}"

# --- sweep: only removes an expired block
hosts
check "block far future" 0 "$HELPER" block --hosts-file "$TMP/hosts" 9999999999 x.com
check "sweep leaves live block" 0 "$HELPER" sweep --hosts-file "$TMP/hosts"
grep -q 'x.com' "$TMP/hosts" || { echo "FAIL: sweep removed live block"; fails=$((fails+1)); }
check "block past" 0 "$HELPER" block --hosts-file "$TMP/hosts" 1000 x.com
check "sweep removes expired" 0 "$HELPER" sweep --hosts-file "$TMP/hosts"
grep -q 'snooze' "$TMP/hosts" && { echo "FAIL: expired block survived sweep"; fails=$((fails+1)); }
check "block indefinite" 0 "$HELPER" block --hosts-file "$TMP/hosts" 0 x.com
check "sweep leaves indefinite" 0 "$HELPER" sweep --hosts-file "$TMP/hosts"
grep -q 'x.com' "$TMP/hosts" || { echo "FAIL: sweep removed indefinite block"; fails=$((fails+1)); }

# --- unterminated block: never swallow content below it
printf '127.0.0.1 localhost\n# >>> snooze >>> until=5\n0.0.0.0 x.com\n10.0.0.5 intranet\n' >"$TMP/hosts"
check "unblock leaves unterminated block alone" 0 "$HELPER" unblock --hosts-file "$TMP/hosts"
grep -q '^10.0.0.5 intranet$' "$TMP/hosts" || { echo "FAIL: content below unterminated marker lost"; fails=$((fails+1)); }
grep -q '>>> snooze' "$TMP/hosts" || { echo "FAIL: unterminated marker must stay as ordinary content"; fails=$((fails+1)); }

check "version" 0 "$HELPER" version
check "refuses real hosts as non-root" 1 "$HELPER" unblock

echo; [[ $fails -eq 0 ]] && echo "scripts: all ok" || { echo "scripts: $fails failure(s)"; exit 1; }
