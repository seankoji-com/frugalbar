# frugalbar — Agent context

> Project conventions for AI agents working in this repo.

## Tools

- **Swift build/test**: `swift build`, `swift test --parallel` — run from `QuotaBar/`
- **Swift 6 strict concurrency**: all targets use `.swiftLanguageMode(.v6)` — no `@unchecked Sendable`, full actor isolation
- **GitHub Operations**: use `mcp__github__*` tools for PRs, issues, code search

## Repository structure

| Path | Purpose |
|------|---------|
| `QuotaBar/` | Native macOS SwiftUI app (Swift 6, macOS 15+) |
| `QuotaBar/Package.swift` | Package manifest with 5 targets |
| `QuotaBar/Sources/QuotaBarCore/` | Domain models, provider adapters, engine, keychain |
| `QuotaBar/Sources/QuotaBarUI/` | SwiftUI views, components, settings |
| `QuotaBar/Sources/QuotaBarApp/` | NSApplication + MenuBarExtra lifecycle |
| `QuotaBar/Tests/` | Unit tests mirror source structure |
| `.github/workflows/quotabar-ci.yml` | CI: build + test on macOS |
| `prototype/` | Legacy AI Studio prototype (Node.js) |

## Architecture

QuotaBar follows a layered architecture:

1. **QuotaBarCore** — no UI dependency. Contains:
   - `QuotaProvider` protocol + 7 vendor adapters
   - `QuotaManager` actor (parallel fetch, cache, state distribution)
   - `KeychainManager` actor + `CredentialStore` (CLI discovery)
   - `CachePolicy`, `BackgroundScheduler`

2. **QuotaBarUI** — depends on QuotaBarCore. SwiftUI views:
   - `PopoverRootView`: fixed 340×420, zero-scroll layout
   - `MetricRowView`, `HeaderSummaryView`, `MetricSectionView`
   - `MicroProgressBar`, `StatusIndicatorDot`, `ResetCountdownBadge`
   - `SettingsView`: tabbed preferences (API keys, general)

3. **QuotaBarApp** — depends on both. Entry point:
   - `AppDelegate`: NSStatusItem + NSPopover lifecycle
   - `QuotaBarApp`: SwiftUI `@main` with `NSApplicationDelegateAdaptor`

## Provider patterns

- All providers are `final class: QuotaProvider, Sendable`
- Constructor accepts optional credential (for DI/testing); falls back to `CredentialStore.apiKey(for:)`
- No-network providers (Claude) return `.unsupported(reason:)` status
- Error returns produce degraded snapshots with `.networkError` status — never throw up to the caller

## Testing

- Tests use Swift Testing framework (`import Testing`)
- Providers tested with empty/invalid credentials — all return degraded snapshots, no network calls
- `QuotaManager` integration test fetches all 7 providers (expects unauthenticated/unsupported in CI)
- UI tests verify rendering for all status types
