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

# --- a stray end marker above a truncated block must not re-arm the swallow
# (same case as Model.parseHosts guards in tests/model.test.mjs)
printf '# <<< snooze <<<\n127.0.0.1 localhost\n# >>> snooze >>> until=5\n10.0.0.5 intranet\n' >"$TMP/hosts"
check "stray end marker above an unterminated block" 0 "$HELPER" unblock --hosts-file "$TMP/hosts"
grep -q '^10.0.0.5 intranet$' "$TMP/hosts" || { echo "FAIL: stray end marker swallowed content below"; fails=$((fails+1)); }

# --- the next write repairs a truncated block instead of arming it: an orphan
# begin marker left above the fresh block would be re-terminated by the fresh
# end marker, and the write after that would swallow everything between.
printf '127.0.0.1 localhost\n# >>> snooze >>> until=5\n10.0.0.5 intranet\n' >"$TMP/hosts"
check "block repairs a truncated marker" 0 "$HELPER" block --hosts-file "$TMP/hosts" 0 x.com
[[ $(grep -c '>>> snooze' "$TMP/hosts") -eq 1 ]] || { echo "FAIL: orphan begin marker survived the write"; fails=$((fails+1)); }
check "unblock after repair" 0 "$HELPER" unblock --hosts-file "$TMP/hosts"
grep -q '^10.0.0.5 intranet$' "$TMP/hosts" || { echo "FAIL: repaired file still swallowed content"; fails=$((fails+1)); }

check "version" 0 "$HELPER" version

if (( EUID != 0 )); then # as root this line would rewrite the real /etc/hosts
  check "refuses real hosts as non-root" 1 "$HELPER" unblock
fi

# The root guard: `unshare -r` gives EUID 0 in a user namespace with no
# privilege at all. The guard fires before $HOSTS is reassigned, so this can
# never reach a file — it just proves sudo's path cannot be aimed elsewhere.
if unshare -r true 2>/dev/null; then
  check "refuses --hosts-file as root" 1 unshare -r "$HELPER" unblock --hosts-file "$TMP/hosts"
fi

# ---------- CLI ----------
SNOOZE="$HERE/bin/snooze"
export SNOOZE_HELPER="$HELPER" SNOOZE_HOSTS_FILE="$TMP/hosts" \
       SNOOZE_STATE_DIR="$TMP/state" SNOOZE_GROUPS_FILE="$TMP/groups.json" \
       SNOOZE_BIN_DIR="$TMP/bin" SNOOZE_NO_TIMER=1 SNOOZE_QUIET=1
mkdir -p "$TMP/state" "$TMP/bin"
cp "$HERE/defaults/groups.json" "$TMP/groups.json"

hosts
check "start blocks selected groups" 0 "$SNOOZE" start --group social --for 2h
grep -q '^0.0.0.0 facebook.com$' "$TMP/hosts" || { echo "FAIL: social not blocked"; fails=$((fails+1)); }
grep -q '^0.0.0.0 www.reddit.com$' "$TMP/hosts" || { echo "FAIL: www expansion missing"; fails=$((fails+1)); }
grep -q 'youtube' "$TMP/hosts" && { echo "FAIL: unselected group blocked"; fails=$((fails+1)); }
u=$(sed -n 's/.*until=\([0-9]*\).*/\1/p' "$TMP/hosts")
now=$(date +%s)
[[ $u -gt $((now + 7100)) && $u -lt $((now + 7300)) ]] || { echo "FAIL: until not ~2h out ($u)"; fails=$((fails+1)); }
jq -e '.groups == ["social"]' "$TMP/state/session.json" >/dev/null || { echo "FAIL: session groups"; fails=$((fails+1)); }

check "status json while active" 0 "$SNOOZE" status --json
jq -e '.enabled == true and .groups == ["social"] and .setup == "ok" and .remaining > 7000' "$TMP/out" >/dev/null \
  || { echo "FAIL: status shape: $(cat "$TMP/out")"; fails=$((fails+1)); }

check "extend adds 30m" 0 "$SNOOZE" extend 30m
u2=$(sed -n 's/.*until=\([0-9]*\).*/\1/p' "$TMP/hosts")
[[ $u2 -eq $((u + 1800)) ]] || { echo "FAIL: extend ($u -> $u2)"; fails=$((fails+1)); }
grep -q '^0.0.0.0 facebook.com$' "$TMP/hosts" || { echo "FAIL: extend lost domains"; fails=$((fails+1)); }

check "stop unblocks" 0 "$SNOOZE" stop
grep -q 'snooze' "$TMP/hosts" && { echo "FAIL: block left after stop"; fails=$((fails+1)); }
[[ -f "$TMP/state/session.json" ]] && { echo "FAIL: session left after stop"; fails=$((fails+1)); }
check "status json idle" 0 "$SNOOZE" status --json
jq -e '.enabled == false and .class == "disabled"' "$TMP/out" >/dev/null || { echo "FAIL: idle status"; fails=$((fails+1)); }

check "start forever" 0 "$SNOOZE" start --forever
grep -q 'until=0' "$TMP/hosts" || { echo "FAIL: forever until"; fails=$((fails+1)); }
check "status forever remaining null" 0 "$SNOOZE" status --json
jq -e '.until == 0 and .remaining == null and .enabled == true' "$TMP/out" >/dev/null || { echo "FAIL: forever status"; fails=$((fails+1)); }
check "stop forever" 0 "$SNOOZE" stop

check "sweep clears expired and session" 0 env SNOOZE_NOW=2000000000 bash -c '
  "$0" start --group video --for 1m && sleep 0 && '"$HELPER"' block --hosts-file "$SNOOZE_HOSTS_FILE" 1000 x.com && "$0" sweep' "$SNOOZE"
grep -q 'snooze' "$TMP/hosts" && { echo "FAIL: sweep left expired block"; fails=$((fails+1)); }

check "start rejects unknown group" 1 "$SNOOZE" start --group nope --for 1h
check "start rejects bad duration" 1 "$SNOOZE" start --for soon
check "extend requires active session" 1 "$SNOOZE" extend 30m

# --- the site expansion must match Model.expandSites, which the widget uses to
# show what it is about to block: whitespace is trimmed off, and a name longer
# than 253 characters is skipped rather than failing the whole start.
long=$(jq -rn '[range(5) | ("a" * 60)] | join(".") + ".com"') # 308 chars, every label legal
jq -n --arg long "$long" '{version: 1, groups: [
  { id: "pad", name: "Padded", sites: [" padded.com "] },
  { id: "long", name: "Long", sites: [$long, "ok.com"] }]}' >"$TMP/groups.json"

hosts
check "start trims whitespace around sites" 0 "$SNOOZE" start --group pad --for 1h
grep -q '^0.0.0.0 padded.com$' "$TMP/hosts" || { echo "FAIL: padded site dropped"; fails=$((fails+1)); }
grep -q '^0.0.0.0 www.padded.com$' "$TMP/hosts" || { echo "FAIL: padded www expansion missing"; fails=$((fails+1)); }

check "start skips an over-long domain" 0 "$SNOOZE" start --group long --for 1h
grep -q '^0.0.0.0 ok.com$' "$TMP/hosts" || { echo "FAIL: valid sibling not blocked"; fails=$((fails+1)); }
grep -q "$long" "$TMP/hosts" && { echo "FAIL: over-long domain reached the hosts file"; fails=$((fails+1)); }
check "stop after expansion checks" 0 "$SNOOZE" stop

# ---------- setup (dry) ----------
check "setup --print never escalates" 0 env -u SNOOZE_HELPER "$SNOOZE" setup --print
grep -q 'NOPASSWD: /usr/local/bin/snooze-helper' "$TMP/out" || { echo "FAIL: sudoers line missing"; fails=$((fails+1)); }
grep -q 'install -Dm755' "$TMP/out" || { echo "FAIL: helper install missing"; fails=$((fails+1)); }
staged=$(mktemp)
echo '%wheel ALL=(root) NOPASSWD: /usr/local/bin/snooze-helper' >"$staged"
check "sudoers line passes visudo" 0 visudo -cf "$staged"
rm -f "$staged"
check "setup seeds default groups" 0 bash -c 'rm -f "$SNOOZE_GROUPS_FILE"; "$0" setup --print >/dev/null; test -f "$SNOOZE_GROUPS_FILE"' "$SNOOZE"
jq -e '.version == 1 and (.groups | length) == 3' "$TMP/groups.json" >/dev/null || { echo "FAIL: seeded groups"; fails=$((fails+1)); }

# --- the link: a stale one (the plugin moved) is repointed, a real file is not
ln -sfn "$TMP/gone" "$TMP/bin/snooze"
check "setup repoints a stale link" 0 env -u SNOOZE_HELPER "$SNOOZE" setup --print
[[ $(readlink "$TMP/bin/snooze") == "$HERE/bin/snooze" ]] || { echo "FAIL: stale link not repointed"; fails=$((fails+1)); }
rm -f "$TMP/bin/snooze"; printf '#!/bin/sh\n' >"$TMP/bin/snooze"
check "setup leaves a file it did not make" 0 env -u SNOOZE_HELPER "$SNOOZE" setup --print
grep -q 'left it alone' "$TMP/out" || { echo "FAIL: no warning about a foreign snooze"; fails=$((fails+1)); }
[[ -L $TMP/bin/snooze ]] && { echo "FAIL: overwrote a file it did not make"; fails=$((fails+1)); }
rm -f "$TMP/bin/snooze"

# ---------- setup state as `status` sees it (SNOOZE_HELPER_BIN is a test seam) ----------
printf '#!/usr/bin/env bash\necho 0\n' >"$TMP/oldhelper"; chmod +x "$TMP/oldhelper"
printf '#!/usr/bin/env bash\necho %s\n' "$(sed -n 's/^VERSION=//p' "$HERE/bin/snooze-helper")" >"$TMP/curhelper"
chmod +x "$TMP/curhelper"
touch "$TMP/state/.setup-done"
check "status reports a missing helper" 0 env -u SNOOZE_HELPER SNOOZE_HELPER_BIN="$TMP/nope" "$SNOOZE" status --json
jq -e '.setup == "missing"' "$TMP/out" >/dev/null || { echo "FAIL: missing helper: $(cat "$TMP/out")"; fails=$((fails+1)); }
check "status reports an outdated helper" 0 env -u SNOOZE_HELPER SNOOZE_HELPER_BIN="$TMP/oldhelper" "$SNOOZE" status --json
jq -e '.setup == "outdated"' "$TMP/out" >/dev/null || { echo "FAIL: outdated helper: $(cat "$TMP/out")"; fails=$((fails+1)); }
check "status reports a current helper" 0 env -u SNOOZE_HELPER SNOOZE_HELPER_BIN="$TMP/curhelper" "$SNOOZE" status --json
jq -e '.setup == "ok"' "$TMP/out" >/dev/null || { echo "FAIL: current helper: $(cat "$TMP/out")"; fails=$((fails+1)); }

# ---------- the privileged plan, with sudo replaced by a recording stub ----------
# Nothing below may reach the real sudo: the stub is proven to be on PATH first
# (a canary the real sudo would reject as a bad option), and the privileged
# tests only run when that proof holds.
mkdir -p "$TMP/shim"
cat >"$TMP/shim/sudo" <<'STUB'
#!/usr/bin/env bash
[[ ${1:-} == --canary ]] && { echo STUB; exit 0; }
printf '%s\n' "$*" >>"$SNOOZE_SUDO_LOG"
args=("$@") # `install -Dm440 <staged> /etc/sudoers.d/snooze`: keep what it would install
[[ ${args[-1]} == /etc/sudoers.d/snooze ]] && cp "${args[-2]}" "$SNOOZE_SUDO_LOG.sudoers"
exit 0
STUB
chmod +x "$TMP/shim/sudo"
export SNOOZE_SUDO_LOG="$TMP/sudo.log"

if [[ $(PATH="$TMP/shim:$PATH" sudo --canary 2>/dev/null) == STUB ]]; then
  : >"$SNOOZE_SUDO_LOG"
  touch "$TMP/state/.setup-done"
  check "setup stops at the flag" 0 env PATH="$TMP/shim:$PATH" "$SNOOZE" setup
  grep -q 'already set up' "$TMP/out" || { echo "FAIL: no already-set-up message"; fails=$((fails+1)); }
  [[ -s $SNOOZE_SUDO_LOG ]] && { echo "FAIL: a set-up box escalated anyway"; fails=$((fails+1)); }

  check "setup --force re-runs the privileged steps" 0 env PATH="$TMP/shim:$PATH" "$SNOOZE" setup --force
  grep -q "install -Dm755 -o root -g root $HERE/bin/snooze-helper /usr/local/bin/snooze-helper" "$SNOOZE_SUDO_LOG" \
    || { echo "FAIL: helper not installed root-owned: $(cat "$SNOOZE_SUDO_LOG")"; fails=$((fails+1)); }
  grep -q 'install -Dm440 -o root -g root .* /etc/sudoers.d/snooze' "$SNOOZE_SUDO_LOG" \
    || { echo "FAIL: sudoers rule not installed 440 root:root"; fails=$((fails+1)); }
  [[ $(cat "$SNOOZE_SUDO_LOG.sudoers" 2>/dev/null) == '%wheel ALL=(root) NOPASSWD: /usr/local/bin/snooze-helper' ]] \
    || { echo "FAIL: staged sudoers content"; fails=$((fails+1)); }
  [[ -f $TMP/state/.setup-done ]] || { echo "FAIL: setup flag not written"; fails=$((fails+1)); }
  [[ -L $TMP/bin/snooze ]] || { echo "FAIL: CLI not linked into BIN_DIR"; fails=$((fails+1)); }

  check "setup rejects a typo instead of escalating" 1 env PATH="$TMP/shim:$PATH" "$SNOOZE" setup --pritn

  : >"$SNOOZE_SUDO_LOG"
  echo '{}' >"$TMP/state/session.json"
  check "uninstall clears everything but the groups" 0 env PATH="$TMP/shim:$PATH" "$SNOOZE" uninstall
  grep -q 'rm -f /etc/sudoers.d/snooze /usr/local/bin/snooze-helper' "$SNOOZE_SUDO_LOG" \
    || { echo "FAIL: sudoers rule and helper not removed: $(cat "$SNOOZE_SUDO_LOG")"; fails=$((fails+1)); }
  [[ -e $TMP/bin/snooze ]] && { echo "FAIL: symlink left behind"; fails=$((fails+1)); }
  [[ -e $TMP/state/session.json ]] && { echo "FAIL: session left behind"; fails=$((fails+1)); }
  [[ -e $TMP/state/.setup-done ]] && { echo "FAIL: setup flag left behind"; fails=$((fails+1)); }
  [[ -f $TMP/groups.json ]] || { echo "FAIL: uninstall took the groups file"; fails=$((fails+1)); }
  grep -q "$TMP/groups.json" "$TMP/out" || { echo "FAIL: uninstall did not say where the groups are"; fails=$((fails+1)); }
else
  echo "FAIL: the sudo stub is not on PATH — skipped the privileged-plan tests"; fails=$((fails+1))
fi

echo; [[ $fails -eq 0 ]] && echo "scripts: all ok" || { echo "scripts: $fails failure(s)"; exit 1; }
