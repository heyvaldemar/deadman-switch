# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/deadman-switch/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/deadman-switch/releases/tag/v1.0.0
