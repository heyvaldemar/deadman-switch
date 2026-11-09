#!/bin/bash
# The check kinds below are dispatched by name from the configuration, as
# `check_$kind`, so shellcheck cannot see any of them being called.
# shellcheck disable=SC2329
# deadman.sh — the conditions that must ALL hold for this host to be considered
# healthy. Run it every few minutes from a timer: on success it pings a
# dead man's switch, on failure it pings the same service's failure endpoint
# with the reason.
#
# WHY A DEAD MAN'S SWITCH AND NOT AN ALERT. An alerting path that dies takes
# its alerts with it, and silence reads as "all clear". Here the absence of a
# ping IS the alarm, so the failure of this script, of the host, of its network
# or of its power all produce the same result as a failed check: the external
# service notices nothing arrived and tells you. Nothing on this machine has to
# be working for that to happen.
#
# WHAT IT IS FOR beyond "is the host up". Docker being up says nothing about
# whether your image-update watcher still checks anything, or whether your
# uptime monitor still probes. So the checks assert that THE WATCHERS ARE
# ALIVE too, not only the things they watch. A watcher that dies quietly is
# worse than no watcher, because you stop looking.
#
# A FALSE ALARM HERE IS EXPENSIVE. It trains you to ignore the one channel that
# is supposed to be trustworthy, so every check must be deterministic. In
# particular NEVER pipe into an early-exiting consumer under `set -o pipefail`:
# `grep -q` and `head` close the pipe, the producer dies of SIGPIPE, the
# pipeline returns 141, and the check fails at random times for no reason. Use
# `grep -c`, which always drains its input.
#
#   deadman.sh              run every check, ping the switch
#   deadman.sh --dry-run    run every check, print the verdict, ping nothing
#   deadman.sh --list       print the checks that would run, and stop

set -uo pipefail

CONF_DIR="${DEADMAN_CHECKS_DIR:-/etc/deadman/checks.d}"
PING_URL="${DEADMAN_PING_URL:-}"
CURL_TIMEOUT="${DEADMAN_CURL_TIMEOUT:-10}"
MODE="${1:-}"

log() { printf '%s\n' "$*"; }

# ------------------------------------------------- what leaves this machine
#
# Two things go out when a run fails: the reason, into the journal and into the
# body of the ping, and the ping itself.
#
# THE REASON IS SOMEBODY ELSE'S OUTPUT. It is whatever the failing command
# printed, or the first bytes of a file a watcher dropped, and it lands on a
# service that was never meant to hold anything private. A wrapper that echoes
# its remote, a script run under `set -x`, a client quoting the URL it could
# not reach: each of those puts `https://user:token@host` into an alarm. So the
# credentials in a URL are cut out before the reason is logged or sent, and
# BEFORE IT IS SHORTENED, because half a URL no longer looks like one and what
# is left of the token would pass straight through.
#
# Only that one shape is removed. It is the one that can be recognised without
# guessing, and a filter that guesses hides the part of the message you needed.
redact() { LC_ALL=C sed -E 's|([A-Za-z][A-Za-z0-9+.-]*://)[^/?#[:space:]]+@|\1<redacted>@|g'; }

# The first N bytes of stdin, with the rest read to the end and thrown away.
# A bare `head` closes the pipe early, which is the mistake described at the
# top of this file: the writer's complaint about it ends up inside the reason.
first_bytes() { head -c "$1"; cat >/dev/null; }

# THE PING URL IS A CREDENTIAL TOO. Whoever holds it can report this host as
# healthy, which is the one thing a dead man's switch must not let anybody else
# do. The install step makes the file that holds it readable by root alone, and
# an argument of a running process is readable by every local account for as
# long as the request takes. So the URL reaches curl on stdin, as a line of
# configuration, and never as an argument.
#
#   ping_switch ""            the run passed
#   ping_switch /fail REASON  the run failed
#
# -f, not bare -s. `curl -s` without -f exits ZERO on an HTTP error, so a
# revoked switch, a renamed check or a service returning 500 would swallow
# every alarm this host raises, silently, and the caller could not tell.
ping_switch() {
  local url="${PING_URL}$1"
  url="${url//\\/\\\\}"; url="${url//\"/\\\"}"
  if [ -n "${2:-}" ]; then
    printf 'url = "%s"\n' "$url" \
      | curl -fsS -m "$CURL_TIMEOUT" --data-raw "$2" --config - >/dev/null 2>&1
  else
    printf 'url = "%s"\n' "$url" \
      | curl -fsS -m "$CURL_TIMEOUT" --config - >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------- check kinds
#
# Each check file in checks.d is `KIND<TAB>NAME<TAB>ARGS`. The kinds below
# exist because each one is a mistake somebody has already made.

# A container is running. Not "exists", not "was started once".
# The systemd kinds go through this rather than calling systemctl directly.
# Not indirection for its own sake: without it neither of them can ever be
# SHOWN a violation, and a check kind that has never failed is exactly what
# this repository argues against everywhere else. tests/e2e-deadman.sh puts a
# stand-in here and asserts both directions.
SYSTEMCTL="${DEADMAN_SYSTEMCTL:-systemctl}"

check_container_running() {
  local c="$1"
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] \
    || { echo "container '$c' is not running"; return 1; }
}

# A container is running AND its healthcheck is not failing. Docker does not
# restart an unhealthy container on its own: `restart: unless-stopped` covers
# a container that EXITS, and a process that crashed inside a container that
# stayed up is exactly the case that policy misses.
check_container_healthy() {
  local c="$1" st
  st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null)"
  [ -n "$st" ] || { echo "container '$c' does not exist"; return 1; }
  case "$st" in
    healthy|none|starting) : ;;
    *) echo "container '$c' is $st"; return 1 ;;
  esac
}

# A file's timestamp is younger than N minutes.
#
# THE POINT OF THIS KIND: a marker nobody reads is bookkeeping, not
# observation. Two markers on the host this came from had been written
# faithfully for months and read by nothing — the off-site mirror could have
# stopped pushing and every report would have stayed green. Whenever something
# starts writing a success marker, the question "what raises the alarm when
# this stops moving?" has to be answered at the same time, not later.
#
# Threshold on the RUN marker, not the CLEAN one. The first answers "did the
# watcher execute", the second "was the result good". Only the first detects a
# watcher that stopped, and a threshold on the second repeats the watcher's own
# alarm for the whole duration of a real problem.
check_fresh() {
  local f="$1" max="$2" age
  [ -f "$f" ] || { echo "$f has never been written"; return 1; }
  age=$(( ( $(date +%s) - $(date -r "$f" +%s) ) / 60 ))
  [ "$age" -lt "$max" ] || { echo "$f last changed ${age}m ago (expected within ${max}m)"; return 1; }
}

# The same, for a marker whose CONTENTS are a unix timestamp. Some writers
# touch a file, some write a stamp into it; both are common and the difference
# is invisible until the check reads the wrong one.
check_stamp() {
  local f="$1" max="$2" v age
  [ -f "$f" ] || { echo "$f has never been written"; return 1; }
  v="$(cat "$f" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) echo "$f does not contain a unix timestamp"; return 1 ;; esac
  age=$(( ( $(date +%s) - v ) / 60 ))
  [ "$age" -lt "$max" ] || { echo "$f last succeeded ${age}m ago (expected within ${max}m)"; return 1; }
}

# A mount is present and writable. A read-only remount after a controller
# glitch is the failure everything survives silently while data quietly stops
# being saved.
#
# The flags are read on every run, which is free and silent; the actual write
# happens at most once an hour, because four spinning disks in a bedroom turn a
# five-minute touch into an audible seek 288 times a night to learn something
# that is almost always readable without writing at all.
check_mount_writable() {
  local m="$1" opts stamp now last
  mountpoint -q "$m" 2>/dev/null || { echo "$m is not mounted"; return 1; }
  opts="$(findmnt -no OPTIONS "$m" 2>/dev/null)"
  case ",$opts," in
    *,ro,*)     echo "$m was remounted READ-ONLY (opts: $opts)"; return 1 ;;
    *shutdown*) echo "$m is in the ext4 SHUTDOWN state (opts: $opts)"; return 1 ;;
  esac
  stamp="${DEADMAN_STATE_DIR:-/var/lib/deadman}/write-test$(echo "$m" | tr '/' '_')"
  mkdir -p "$(dirname "$stamp")"
  now=$(date +%s); last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $(( now - last )) -ge 3600 ]; then
    touch "$m/.deadman-write-test" 2>/dev/null \
      || { echo "$m is not writable"; return 1; }
    rm -f "$m/.deadman-write-test"
    printf '%s' "$now" > "$stamp"
  fi
}

# A file exists and is non-empty — for watchers that DROP a file when they find
# something critical. Routing that through here means a disk failure also
# reaches you by a channel that does not depend on this machine being alive.
check_absent() {
  local f="$1"
  # Redacted, then cut. No more than the first 64 KiB is read on the way: a
  # watcher's finding is a few lines, and a runaway file must not hold the run.
  [ -s "$f" ] && { echo "$(basename "$f"): $(head -c 65536 "$f" | redact | first_bytes 300)"; return 1; }
  return 0
}

# No systemd unit is sitting in the failed state.
#
# THE CASE THIS COVERS: a task that STARTS and dies partway — an OOM kill, a
# panic, the power going — never reaches its own failure handler, so the
# message it would have sent is never sent. systemd knows immediately. One
# check rather than a marker in every script, deliberately: this covers units
# added next year without anybody remembering to add anything.
#
# AN UNREADABLE BUS AND A CLEAN BUS ARE DIFFERENT FACTS. The first version of
# this swallowed stderr and treated empty output as "nothing failed" — so if
# systemctl could not answer at all it reported everything fine, forever, in
# the confident tone of a working check.
check_no_failed_units() {
  local out failed
  if ! out=$("$SYSTEMCTL" list-units --state=failed --no-legend --plain 2>&1); then
    echo "cannot query systemd for failed units: $(printf '%s' "$out" | head -1)"
    return 1
  fi
  failed=$(printf '%s' "$out" | awk '{print $1}' | tr '\n' ' ')
  [ -z "${failed// /}" ] || { echo "systemd units failed: ${failed% }"; return 1; }
}

# TWO INDEPENDENT ANSWERS TO THE SAME QUESTION, AND THEY MUST AGREE.
#
# Everything above asks one source one question, which is enough while the
# source is honest. It stops being enough for the things that REPORT on other
# things: a status page, an inventory, a report that says how many jobs ran. If
# one of those goes wrong it goes wrong confidently, and its wrongness is
# indistinguishable from good news — nothing else is looking at the same fact.
#
# So ask twice, from two places that cannot fail the same way, and compare.
# On the host these rules come from, asking "how many timers are scheduled?" of
# systemd and of the table that is supposed to list them disagreed by five:
# five timers were firing on a schedule nobody had written down. Every report
# on that machine had been green throughout, because every report read the
# table.
#
#   agree<TAB>the timer table is complete<TAB>systemctl list-timers ... | wc -l ::: wc -l < /etc/timers.tsv
#
# The two commands are separated by ` ::: `. Both run under sh -c; the check
# fails when their output differs, and says both answers.
check_agree() {
  local spec="$*" left right a b said_a said_b
  case "$spec" in *' ::: '*) ;; *) echo "agree needs two commands separated by ' ::: '"; return 1 ;; esac
  left="${spec%% ::: *}"; right="${spec#* ::: }"
  said_a="$(sh -c "$left" 2>&1)"; said_b="$(sh -c "$right" 2>&1)"
  # Whitespace differs between two tools answering the same question far more
  # often than the answer does.
  a="$(printf '%s' "$said_a" | tr -d '[:space:]')"; b="$(printf '%s' "$said_b" | tr -d '[:space:]')"
  if [ -z "$a" ] && [ -z "$b" ]; then
    # Both silent is not agreement, it is two commands that did not run.
    echo "both sides answered nothing — a question with no answer is not two answers that agree"
    return 1
  fi
  [ "$a" = "$b" ] && return 0
  # What gets quoted is redacted while its whitespace is still there to end a
  # URL, and only then squeezed the way it was compared.
  a="$(printf '%s' "$said_a" | redact | tr -d '[:space:]' | first_bytes 80)"
  b="$(printf '%s' "$said_b" | redact | tr -d '[:space:]' | first_bytes 80)"
  echo "the two sides disagree: '$a' against '$b'"
  return 1
}

# EVERY ENABLED TIMER STILL HAS THE SERVICE IT STARTS.
#
# A timer whose unit was deleted does not fail. It fires, systemd finds nothing
# to start, and the job silently never runs again — so no_failed_units above
# cannot see it, and neither can anything that waits for a failure. Five of
# these were found on the host this comes from, left behind by scripts that had
# been renamed or removed.
check_orphan_timers() {
  local out orphans="" t unit
  if ! out=$("$SYSTEMCTL" list-timers --all --no-legend --no-pager 2>&1); then
    echo "cannot query systemd for timers: $(printf '%s' "$out" | head -1)"
    return 1
  fi
  while read -r t; do
    [ -n "$t" ] || continue
    unit="$("$SYSTEMCTL" show -p Unit --value "$t" 2>/dev/null)"
    [ -n "$unit" ] || unit="${t%.timer}.service"
    # LoadState, not "is it running": the service of a timer is inactive
    # almost all the time by design. What matters is whether systemd can find
    # it at all.
    case "$("$SYSTEMCTL" show -p LoadState --value "$unit" 2>/dev/null)" in
      loaded) ;;
      *) orphans="$orphans $t" ;;
    esac
  done < <(printf '%s\n' "$out" | awk '{for(i=1;i<=NF;i++) if ($i ~ /\.timer$/) print $i}')
  [ -z "${orphans// /}" ] || { echo "enabled timers whose service does not exist:${orphans}"; return 1; }
}

# Anything else. The command runs under `sh -c`; a non-zero exit fails the run
# and its output becomes the reason.
#
# A command that fails without a word is reported by its exit code and not by
# its own command line. That line is configuration: it can hold a URL, a header
# or a flag that the command's output never would, and the name of the check
# already says which one failed.
check_command() {
  local out rc
  out="$(sh -c "$*" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ -n "$out" ]; then
    printf '%s' "$out" | redact | first_bytes 300
  else
    echo "command failed with exit $rc and no output"
  fi
  return 1
}

# ------------------------------------------------------------------ the run
checks=()
while IFS= read -r -d '' f; do checks+=("$f"); done \
  < <(find "$CONF_DIR" -maxdepth 1 -type f -name '*.checks' -print0 2>/dev/null | sort -z)

if [ "${#checks[@]}" -eq 0 ]; then
  # Refusing to report a green run that checked nothing. An empty configuration
  # is a misconfiguration, and the one thing it must not do is look healthy.
  log "deadman: no checks found in $CONF_DIR"
  [ "$MODE" = "--dry-run" ] || [ "$MODE" = "--list" ] || {
    [ -n "$PING_URL" ] && ping_switch /fail "no checks configured in $CONF_DIR"
  }
  exit 1
fi

failures=0
reason=""
ran=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  kind="$(printf '%s' "$line" | cut -f1)"
  name="$(printf '%s' "$line" | cut -f2)"
  args="$(printf '%s' "$line" | cut -f3-)"
  [ -n "$kind" ] && [ -n "$name" ] || continue
  ran=$((ran+1))
  if [ "$MODE" = "--list" ]; then log "  $kind  $name  $args"; continue; fi
  # shellcheck disable=SC2086
  if out="$(check_"$kind" $args 2>&1)"; then
    [ "$MODE" = "--dry-run" ] && log "  ok    $name"
  else
    # Every kind's reason passes through here, whatever produced it.
    out="$(printf '%s' "$out" | redact)"
    [ "$MODE" = "--dry-run" ] && log "  FAIL  $name: $out"
    failures=$((failures+1))
    [ -z "$reason" ] && reason="$name: $out"
  fi
done < <(cat "${checks[@]}")

[ "$MODE" = "--list" ] && exit 0

if [ "$ran" -eq 0 ]; then
  log "deadman: the check files exist but define no checks"
  [ "$MODE" = "--dry-run" ] || { [ -n "$PING_URL" ] && ping_switch /fail "check files define nothing"; }
  exit 1
fi

if [ "$failures" -gt 0 ]; then
  log "deadman: $failures of $ran checks failed — $reason"
  [ "$MODE" = "--dry-run" ] && exit 1
  if [ -n "$PING_URL" ]; then
    ping_switch /fail "$reason" \
      || log "deadman: could not reach the switch to report the failure"
  fi
  exit 1
fi

log "deadman: all $ran checks passed"
[ "$MODE" = "--dry-run" ] && exit 0
if [ -n "$PING_URL" ]; then
  ping_switch "" \
    || { log "deadman: checks passed but the switch could not be reached"; exit 1; }
fi
exit 0
