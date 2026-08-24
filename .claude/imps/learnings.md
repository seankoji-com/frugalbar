# frugalbar — /imps learnings

## Active rules

- When a run's Global Constraints forbid `UNUserNotificationCenter` due to a confirmed bundle-identity crash on an unbundled release binary, verify the `osascript`/`Process` alternative actually exits 0 before building the feature around it — require that as a first concrete step, not an assumption.

## 2026-08-24 — frugalbar quota-recovery notifications

- When a run's Global Constraints forbid `UNUserNotificationCenter` due to a confirmed bundle-identity crash on an unbundled release binary, verify the `osascript`/`Process` alternative actually exits 0 before building the feature around it — this run correctly required that as a first concrete step. (Landed as opt-in quota-recovery notifications via osascript.)
