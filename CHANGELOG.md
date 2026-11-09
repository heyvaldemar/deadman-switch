# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.2.1] - 2026-11-09

### Security

- **A failure reason no longer carries a URL's credentials off the machine.**
  The reason is the failing check's own output. It goes into the journal and
  into the body of the ping, on a service that was never meant to hold anything
  private. A wrapper that echoes its remote, a script run under `set -x` or a
  client quoting the address it could not reach puts `https://user:token@host`
  into an alarm. The user-info part of every URL is now replaced with
  `<redacted>` in each place a reason comes from: a command's output, the two
  answers `agree` quotes and the file `absent` reads. The redaction runs before
  the reason is shortened. A URL cut at the 300-byte limit loses its `@`, stops
  looking like a URL, and the first half of the token used to go out untouched.
- **A command that fails without output no longer sends its own command line.**
  The fallback reason was `command failed: <the command>`, and that line is
  configuration: it can hold a URL, a header or a flag the command's output
  never would. The reason is now `command failed with exit N and no output`.
  The check's name already says which one failed.
- **The ping URL is no longer an argument of `curl`.** Whoever holds that URL
  can report the host as healthy. The install step keeps it in a file only root
  can read, and every run then put it on a command line, which any local
  account can read for as long as the request takes. It now reaches `curl` on
  stdin, as a `--config -` line.

### Fixed

- **The cuts that shorten a reason read their input to the end.** The 1.0.0
  notes say nothing here pipes into `head`. Three cuts did. Under systemd,
  which ignores SIGPIPE, a failing command that printed more than a pipe's
  worth had `echo: write error: Broken pipe` appended to its reason.

### Changed

- `absent` reads at most the first 64 KiB of the file it quotes. A watcher's
  finding is a few lines, and a runaway file must not hold the run.
- Seven scenarios. Six of them fail against 1.2.0, one for each path above.
  The seventh runs the other way: a URL with no credentials in it, and an
  address after the `?`, arrives exactly as it was printed. For the ping URL
  the suite swaps `curl` for a stand-in that records the arguments it was
  started with, which is what `ps` would have shown.

## [1.2.0] - 2026-09-22

### Added

- **Where this tool's watching ends, and what takes over.** A reboot commanded on a host with processes wedged in uninterruptible sleep is accepted and never completes; the alarm this raises is correct and nothing in software can act on it. The README now names the kernel watchdog that can — `RuntimeWatchdogSec` and `RebootWatchdogSec`, with the check that the device exists first, since on a machine without one those settings are accepted and do nothing.

## [1.1.0] - 2026-09-14

### Added

- **`agree`: two independent answers to the same question, which must match.**
  Every other kind asks one source one question, which is enough while the
  source is honest and stops being enough for anything that reports on other
  things. On the host these rules come from, systemd and the table that was
  supposed to list its timers disagreed by five — five timers firing on a
  schedule nobody had written down, while every report stayed green because
  every report read the table. Both sides answering nothing is a failure
  rather than agreement: two commands that produce no output compare equal,
  which is what a check that has quietly stopped checking looks like.
- **`orphan_timers`: every enabled timer still has the service it starts.** A
  timer whose unit was deleted does not fail. It fires, systemd finds nothing
  to start, and the job silently never runs again, so `no_failed_units` cannot
  see it and neither can anything waiting for a failure. Five were found on
  the host this comes from, left behind by renamed scripts.
- Six scenarios, both directions each. The two systemd kinds now go through an
  overridable `$SYSTEMCTL`, because without that seam neither could ever be
  shown a violation — and a check kind that has never failed is the thing this
  repository argues against everywhere else.

## [1.0.0] - 2026-09-05

### Added

- **Eight check kinds, configured one per line**, covering containers, freshness
  markers, timestamp markers, a writable mount, a critical-finding file, failed
  systemd units and arbitrary commands.
- **Checks for the watchers, not only the workload.** Docker being up says
  nothing about whether the thing watching your images still checks anything.
- **A failure endpoint that carries the reason.** The first failing check's name
  and message travel with the alarm, so the notification says what broke rather
  than that something did.
- **An empty configuration is a failure.** A checks directory with nothing in it
  pings the failure endpoint rather than reporting a green run that verified
  nothing.
- **`--dry-run` and `--list`**, so the configuration can be seen and exercised
  before it is able to page anyone.
- **Twelve end-to-end scenarios** against real containers and a local HTTP
  server that records what was requested, so every claim about reporting is a
  measurement rather than a reading of the source.

### Notes on what the checks refuse to do

- Every request uses `curl -f`. Without it `curl` exits zero on an HTTP error,
  and a revoked switch would swallow every alarm the host raises while the
  caller saw success.
- A run whose checks pass but whose ping does not land exits non-zero. Checks
  passing is not the same as the switch having been told.
- Nothing pipes into `grep -q` or `head` under `pipefail`: the producer dies of
  SIGPIPE, the pipeline returns 141, and the check fails at random. A false
  alarm here trains people to ignore the one channel that is meant to be
  trustworthy.
- The systemd check distinguishes an unreadable bus from a clean one. Treating
  empty output as "nothing failed" reports a host that cannot answer as healthy,
  forever.

[Unreleased]: https://github.com/heyvaldemar/deadman-switch/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/heyvaldemar/deadman-switch/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/deadman-switch/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/deadman-switch/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/deadman-switch/releases/tag/v1.0.0
