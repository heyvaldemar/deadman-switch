# Dead man's switch

[![Deadman Tests](https://github.com/heyvaldemar/deadman-switch/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/deadman-switch/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An alerting path that dies takes its alerts with it, and silence reads as "all clear".

This inverts that. Every few minutes it checks the conditions that must hold for your host to be healthy and pings an external switch. The absence of a ping is the alarm, so a dead script, a dead host, a dead network and a cut power supply all produce the same result as a failed check: something off this machine notices nothing arrived, and tells you. Nothing here has to be working for that to happen.

## The part people leave out

Docker being up says nothing about whether your image-update watcher still checks anything, or whether your uptime monitor still probes. So assert that the watchers are alive too:

```
container_running	the image-update watcher	diun
container_running	the uptime monitor	uptime-kuma
stamp	the off-site mirror	/var/lib/git-mirror/last-run 90
```

A watcher that dies quietly is worse than no watcher, because you stop looking.

The third line is the one worth copying. Two markers on the host this came from had been written faithfully for months and read by nothing: the off-site mirror could have stopped pushing — an expired deploy key, a rejected commit — and every report would have stayed green while the only copy of that machine's configuration went stale. Whenever something starts writing a success marker, the question "what raises the alarm when this stops moving?" has to be answered at the same time, not later.

Threshold on the marker that says the job **ran**, not the one that says the result was clean. The first detects a job that stopped; a threshold on the second repeats the job's own alarm for the whole duration of a real problem, and says nothing at all when the job simply disappears.

## Install

```bash
sudo install -m 755 deadman.sh /usr/local/sbin/deadman.sh
sudo install -m 644 deadman@.service deadman@.timer /etc/systemd/system/
sudo mkdir -p /etc/deadman/checks.d
sudo cp deadman.env.example /etc/deadman/host.env && sudo chmod 600 /etc/deadman/host.env
sudo cp checks.d/10-example.checks /etc/deadman/checks.d/
sudo $EDITOR /etc/deadman/host.env /etc/deadman/checks.d/10-example.checks
```

See what it would do before it can page anyone:

```bash
sudo DEADMAN_CHECKS_DIR=/etc/deadman/checks.d /usr/local/sbin/deadman.sh --dry-run
sudo systemctl enable --now deadman@host.timer
```

`--dry-run` runs every check and pings nothing. `--list` prints what is configured and stops.

## Checks

One per line: `KIND<TAB>NAME<TAB>ARGUMENTS`, in any file under `checks.d` ending in `.checks`.

| Kind | Asserts |
|---|---|
| `container_running` | the container exists and is running |
| `container_healthy` | it is running and its healthcheck is not failing |
| `fresh` | a file was modified within N minutes |
| `stamp` | a file containing a unix timestamp says N minutes or less |
| `mount_writable` | a mount is present, not read-only, and accepts a write |
| `absent` | a file a watcher drops on a critical finding is empty or gone |
| `no_failed_units` | no systemd unit is in the failed state |
| `command` | any command exits zero |

`no_failed_units` is worth having even if you check nothing else. A task killed partway — an OOM kill, a panic, the power going — never reaches its own failure handler, so the message it would have sent is never sent. systemd knows immediately, and one line covers every unit on the host including the ones added next year, with nobody having to remember anything when they add one.

`mount_writable` reads the mount flags on every run, which is free and silent, and does a real write at most once an hour. Four spinning disks in a bedroom turn a five-minute touch into an audible seek 288 times a night, to learn something that is almost always readable without writing at all.

## Things that took a while to learn

**`curl -s` without `-f` exits zero on an HTTP error.** A revoked switch, a renamed check or a service returning 500 will swallow every alarm a host raises, and the caller cannot tell. Every request here uses `-f`, and a passing run whose ping does not land exits non-zero rather than reporting success.

**Never pipe into an early-exiting consumer under `pipefail`.** `grep -q` and `head` close the pipe, the producer dies of SIGPIPE, the pipeline returns 141, and the check fails at random for no reason. Use `grep -c`, which drains its input. A false alarm here is expensive: it trains you to ignore the one channel that is supposed to be trustworthy.

**An unreadable bus and a clean bus are different facts.** An early version of the systemd check swallowed stderr and treated empty output as "nothing failed", so a host where `systemctl` could not answer at all reported everything fine, forever, in the confident tone of a working check.

**An empty configuration is a failure, not a pass.** A checks directory with nothing in it pings the failure endpoint. The one thing a misconfiguration must never do is look healthy.

## Testing

`tests/e2e-deadman.sh` gives every check kind a real violation and fails the run if the kind stays quiet, against real containers and a local HTTP server that records what was actually requested — so "did it report" is a measurement, not a reading of the source.

Twelve scenarios, including the four that are easy to get wrong: an empty configuration reports a failure rather than a green run, the failing check's name travels with the alarm instead of a bare red light, a marker that never existed is reported differently from one that stopped moving, and a switch that cannot be reached fails the run instead of passing quietly.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
