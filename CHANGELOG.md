# Changelog

All notable changes to Plan Mode Crosscheck. Follows SemVer.

## 1.0.0

Initial public release. Ported from a personal `UserPromptSubmit` hook after
three rounds of design, live end-to-end verification against real Codex CLI,
and bugfixing (temp file leak, stderr log rotation, byte-accurate output
truncation, auth-failure diagnosis). See the plugin's `hooks/crosscheck.sh`
for the full behavior: fresh/resume thread lifecycle, auto-expiry by age or
turn count, `[nocheck]`/`[freshcheck]` escape hatches, and a `--selftest`
harness covering all of it against a stubbed Codex binary.
