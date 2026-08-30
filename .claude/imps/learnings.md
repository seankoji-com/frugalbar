# frugalbar — /imps learnings

## Active rules

- When a run's Global Constraints forbid `UNUserNotificationCenter` due to a confirmed bundle-identity crash on an unbundled release binary, verify the `osascript`/`Process` alternative actually exits 0 before building the feature around it — require that as a first concrete step, not an assumption.

## 2026-08-24 — frugalbar quota-recovery notifications

- When a run's Global Constraints forbid `UNUserNotificationCenter` due to a confirmed bundle-identity crash on an unbundled release binary, verify the `osascript`/`Process` alternative actually exits 0 before building the feature around it — this run correctly required that as a first concrete step. (Landed as opt-in quota-recovery notifications via osascript.)

## 2026-08-30 — frugalbar audit-fix batch

- **Grouping fix tasks by file ownership does not fully prevent cross-file coupling when one task's spec changes a widely-referenced model type.** A single Optional-type refactor (`DualBarMetrics.primaryFraction` `Double` → `Double?`) rippled into 5+ files owned by other tasks, requiring ad hoc one-line compile fixes flagged for the integrator. When a task's spec touches a widely-referenced model type, either give it an explicit downstream-file list up front or split it into its own dedicated "shared type change" task rather than trusting file-ownership partitioning alone.
