#!/bin/bash
# Can every check kind actually fail, and does the switch report it?
#
# A dead man's switch is the one channel that is supposed to be trustworthy, so
# a check kind that cannot fail is worse here than anywhere else: it makes the
# report confident and wrong. Each kind below is given a real violation, and
# the run fails if it stays quiet.
#
# The ping path is exercised against a local HTTP server, so the assertions are
# about what was actually requested rather than about what the code looks like.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEADMAN="$ROOT/deadman.sh"
WORK="$(mktemp -d)"
RUN="deadmantest-$$"
PASSED=0; FAILED=0

cleanup() {
  [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null
  docker rm -f "$RUN-up" "$RUN-sick" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

mkdir -p "$WORK/checks.d" "$WORK/state"

# A ping target that records what it was asked for, so "did it report" is a
# measurement rather than a reading of the source.
cat > "$WORK/server.py" <<'PY'
import http.server, sys, threading
LOG = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _rec(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
        with open(LOG, 'a') as f:
            f.write(f"{self.path}\t{body}\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    do_GET = do_POST = _rec
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
# Let the kernel choose a free port rather than guessing one: a fixed guess
# collides on a busy runner, and an arithmetic guess can leave the valid range
# entirely, which is how the first version of this file silently ran every
# ping assertion against a server that had never started.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 "$WORK/server.py" "$PORT" "$WORK/pings.log" &
SRV_PID=$!
up=false
for _ in $(seq 1 60); do
  if curl -fsS -m 1 "http://127.0.0.1:$PORT/probe" >/dev/null 2>&1; then up=true; break; fi
  sleep 0.25
done
[ "$up" = true ] || { echo "the ping server never came up on port $PORT - every ping assertion below would be meaningless"; exit 1; }
: > "$WORK/pings.log"

# shellcheck disable=SC2120  # the optional argument is a mode flag, usually unset
run_deadman() {
  DEADMAN_CHECKS_DIR="$WORK/checks.d" DEADMAN_PING_URL="http://127.0.0.1:$PORT/switch" \
  DEADMAN_STATE_DIR="$WORK/state" bash "$DEADMAN" "${1:-}" 2>&1
}
only() { printf '%s\n' "$1" > "$WORK/checks.d/case.checks"; }
last_ping() { tail -1 "$WORK/pings.log" 2>/dev/null; }

echo "=== deadman: can every check kind fail? ==="
echo

# ------------------------------------------------------------------ control
docker rm -f "$RUN-up" >/dev/null 2>&1
docker run -d --name "$RUN-up" --health-cmd 'true' --health-interval 2s \
  alpine sh -c 'sleep 3600' >/dev/null 2>&1
printf 'container_running\tthe test container\t%s\n' "$RUN-up" > "$WORK/checks.d/case.checks"
: > "$WORK/pings.log"
if run_deadman >/dev/null 2>&1 && printf '%s' "$(last_ping)" | grep -q '^/switch'; then
  pass "a healthy host pings the switch, not the failure endpoint"
else
  fail "a healthy host did not ping the switch"; cat "$WORK/pings.log"
fi

# ------------------------------------------------------------- each kind fails
only "$(printf 'container_running\ta container that does not exist\tno-such-container-%s' "$RUN")"
: > "$WORK/pings.log"; run_deadman >/dev/null 2>&1
if printf '%s' "$(last_ping)" | grep -q '^/switch/fail'; then pass "a missing container fails and reports to /fail"; else fail "a missing container did not report"; fi

docker rm -f "$RUN-sick" >/dev/null 2>&1
docker run -d --name "$RUN-sick" --health-cmd 'exit 1' --health-interval 2s --health-retries 1 \
  alpine sh -c 'sleep 3600' >/dev/null 2>&1
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$RUN-sick" 2>/dev/null)" = "unhealthy" ] && break
  sleep 1
done
only "$(printf 'container_healthy\tthe sick container\t%s' "$RUN-sick")"
: > "$WORK/pings.log"; out="$(run_deadman)"
if printf '%s' "$out" | grep -q 'is unhealthy'; then
  pass "a running but unhealthy container is caught"
else
  fail "an unhealthy container passed"; printf '%s\n' "$out" | sed 's/^/        /'
fi

only "$(printf 'fresh\tan old marker\t%s/ancient 60' "$WORK")"
touch -t 202001010000 "$WORK/ancient"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q 'last changed'; then pass "a marker that stopped moving is caught"; else fail "a stale marker passed"; fi

only "$(printf 'fresh\ta marker that was never written\t%s/never 60' "$WORK")"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q 'never been written'; then pass "a marker that never existed is caught, and says so differently"; else fail "a missing marker passed"; fi

only "$(printf 'stamp\tan old timestamp\t%s/stamp 60' "$WORK")"
echo $(( $(date +%s) - 7200 )) > "$WORK/stamp"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q 'last succeeded'; then pass "a timestamp-in-file marker that stopped moving is caught"; else fail "a stale stamp passed"; fi

only "$(printf 'stamp\ta marker holding something else\t%s/garbage 60' "$WORK")"
echo "not a timestamp" > "$WORK/garbage"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q 'does not contain a unix timestamp'; then pass "a marker holding the wrong thing is caught rather than read as zero"; else fail "a garbage stamp was misread"; fi

only "$(printf 'absent\ta critical finding\t%s/critical' "$WORK")"
echo "two disks are failing" > "$WORK/critical"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q 'two disks are failing'; then pass "a dropped critical file is caught and its contents are quoted"; else fail "a critical file was ignored"; fi

only "$(printf 'command\tan arbitrary command\tfalse')"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q 'command failed'; then pass "an arbitrary failing command is caught"; else fail "a failing command passed"; fi

# ------------------------------------------------ two answers that must agree
#
# The kind that exists for the things which REPORT on other things: if one of
# those goes wrong it goes wrong confidently, and nothing else is looking at the
# same fact. On the host these rules come from, systemd and the table that was
# supposed to list its timers disagreed by five.
only "$(printf 'agree\tthe two counts\techo 7 ::: echo 7')"
out="$(run_deadman --dry-run)"
if printf '%s' "$out" | grep -q '  ok    the two counts'; then
  pass "two sides that answer the same thing agree"
else
  fail "two identical answers were called a disagreement"; printf '%s\n' "$out" | sed 's/^/        /' | tail -3
fi

only "$(printf 'agree\tthe two counts\techo 7 ::: echo 12')"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q "disagree: '7' against '12'"; then
  pass "two sides that disagree are caught, and both answers are quoted"
else
  fail "a disagreement passed"; printf '%s\n' "$out" | sed 's/^/        /' | tail -3
fi

# BOTH SILENT IS NOT AGREEMENT. Two commands that produce nothing — a typo in
# both, a tool that is not installed — compare equal, and that is exactly the
# shape of a check that has quietly stopped checking.
only "$(printf 'agree\tthe two counts\ttrue ::: true')"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q 'both sides answered nothing'; then
  pass "two sides that both say nothing is a failure, not agreement"
else
  fail "silence on both sides was read as agreement"; printf '%s\n' "$out" | sed 's/^/        /' | tail -3
fi

only "$(printf 'agree\tthe two counts\techo 7')"
out="$(run_deadman)"
if printf '%s' "$out" | grep -q "separated by"; then
  pass "a single command is refused rather than compared against nothing"
else
  fail "a malformed agree check passed"; printf '%s\n' "$out" | sed 's/^/        /' | tail -3
fi

# ------------------------------------------- a timer whose service is gone
#
# It does not fail. It fires, systemd finds nothing to start, and the job
# silently never runs again — so the failed-units check cannot see it and
# neither can anything that waits for a failure. Five of these were found on
# the host these rules come from, left by scripts that had been renamed.
#
# systemd is not available on every runner and cannot be made to hold a broken
# timer on demand, so the two kinds that ask it go through $SYSTEMCTL and a
# stand-in answers here. Without that seam neither kind could ever be shown a
# violation, which is the thing this whole file exists to refuse.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'FAKE'
#!/bin/sh
# Two timers. backup.timer's service is loaded; ghost.timer's is not — exactly
# what a timer left behind by a deleted script looks like.
case "$1 $2" in
  "list-timers --all")
    echo "Mon 2026-09-15 06:00:00 UTC 12h left n/a n/a backup.timer backup.service"
    echo "Mon 2026-09-15 07:00:00 UTC 13h left n/a n/a ghost.timer ghost.service"
    ;;
  "list-units --state=failed") ;;
  "show -p")
    # the unit is the LAST argument: systemctl show -p Unit --value <unit>
    for a in "$@"; do u="$a"; done
    case "$u" in
      backup.timer) echo backup.service ;;
      ghost.timer)  echo ghost.service ;;
      backup.service) echo loaded ;;
      ghost.service)  echo not-found ;;
    esac
    ;;
esac
FAKE
chmod +x "$WORK/bin/systemctl"
fakectl() { DEADMAN_SYSTEMCTL="$WORK/bin/systemctl" run_deadman "${1:-}"; }

only "$(printf 'orphan_timers\tevery timer still has its service')"
out="$(fakectl)"
if printf '%s' "$out" | grep -q 'ghost.timer' && ! printf '%s' "$out" | grep -q 'backup.timer'; then
  pass "a timer whose service no longer exists is caught, and the healthy one is not named"
else
  fail "an orphan timer passed"; printf '%s\n' "$out" | sed 's/^/        /' | tail -3
fi

# And the other direction, on the same stand-in with the ghost removed: the
# rule must go quiet rather than being satisfied by anything.
sed -i.bak '/ghost/d' "$WORK/bin/systemctl" && rm -f "$WORK/bin/systemctl.bak"
out="$(fakectl --dry-run)"
if printf '%s' "$out" | grep -q '  ok    every timer still has its service'; then
  pass "timers that all have their services are reported clean"
else
  fail "a clean set of timers was reported as broken"; printf '%s\n' "$out" | sed 's/^/        /' | tail -3
fi

# --------------------------------------------------- an empty configuration
# The one thing a misconfiguration must not do is look healthy.
rm -f "$WORK/checks.d"/*.checks
: > "$WORK/pings.log"
run_deadman >/dev/null 2>&1
if printf '%s' "$(last_ping)" | grep -q '^/switch/fail'; then
  pass "no checks configured reports a failure instead of a green run"
else
  fail "an empty configuration looked healthy"
fi

# ------------------------------------------- the reason travels with the ping
only "$(printf 'command\tthe named check\texit 3')"
: > "$WORK/pings.log"; run_deadman >/dev/null 2>&1
if printf '%s' "$(last_ping)" | grep -q 'the named check'; then
  pass "the failing check's name is sent with the alarm, not just a red light"
else
  fail "the alarm carried no reason"; cat "$WORK/pings.log"
fi

# ------------------------------------------------ a switch that is not there
# curl -s without -f exits ZERO on an HTTP error, so a revoked switch would
# swallow every alarm silently. The run must not report success.
printf 'command\ta passing check\ttrue\n' > "$WORK/checks.d/case.checks"
# A port nothing listens on. Pointing at a path on the live server would not
# test this: that server answers 200 to anything, so the "unreachable" switch
# was reachable and the assertion passed for the wrong reason on its first run.
DEAD_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); print(p)')"
if DEADMAN_CHECKS_DIR="$WORK/checks.d" DEADMAN_PING_URL="http://127.0.0.1:$DEAD_PORT/switch" \
   DEADMAN_STATE_DIR="$WORK/state" bash "$DEADMAN" >/dev/null 2>&1; then
  fail "checks passed but the switch was unreachable and the run still succeeded"
else
  pass "an unreachable switch fails the run rather than passing quietly"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
