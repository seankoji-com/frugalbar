# Swift CodeQL analysis removal

Decision: Swift sources are no longer analysed by CodeQL in this repository.

Approved by the repository owner on 27 October 2026.

## Why

`Analyze (swift)` took 16 minutes on `main` (run 40490376170 on 27 October 2026), most of
it in the traced Swift build. Every job in the organisation must finish inside ten
minutes, so the Swift job could not stay as it was.

## What changed

- `.github/workflows/codeql.yml` keeps only `Analyze (actions)`. The `profile` dispatch
  input and the Swift job are gone.
- The Swift-only helpers and their tests are deleted: `scripts/codeql-build.py`,
  `scripts/codeql-profile.py`, `scripts/test_codeql_build.py`,
  `scripts/test_codeql_profile.py`.
- `.github/skills/code-review/SKILL.md` points here instead of describing CodeQL as the
  Swift coverage gate.

## Coverage this removes

Swift sources are no longer scanned by CodeQL, so injection and taint patterns in Swift
are no longer caught by an automated scanner. `quotabar-ci.yml` still builds, tests and
lints Swift, and the reusable static-analysis workflow still runs (non-blocking). Neither
performs Swift data-flow analysis.

Swift changes therefore need human review for injection and taint patterns until a
blocking Swift scanner replaces the removed job.

## Coupling to watch

The `push.paths` filter in `.github/workflows/codeql.yml` is deliberately narrow: it
triggers on workflow files only. If a Swift job is ever re-added to that workflow, the
filter must be widened to `Sources/**` and `Package*.swift` at the same time, otherwise
Swift pushes to `main` will never be analysed and nothing will report the gap.

## Reopening this decision

A replacement Swift scanner has to fit the ten-minute job budget — for example an
incremental or sharded analysis, or a lighter taint tool. Adding one is the preferred
resolution; until then this document is the tracked record that the coverage is gone.
