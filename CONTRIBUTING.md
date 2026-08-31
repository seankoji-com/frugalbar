# Contributing to FrugalBar

Thank you for your interest in contributing to **FrugalBar**! We welcome bug fixes, documentation improvements, provider integrations, and performance optimizations.

---

## Architecture Overview

FrugalBar is structured into modular Swift targets:
- **`QuotaBarCore`**: Business logic, provider implementations, keychain credential storage, telemetry caching, and background schedulers.
- **`QuotaBarUI`**: SwiftUI menu bar and popover views, status indicators, and preference panels.
- **`QuotaBarApp`**: Entry point and application lifecycle.

---

## Core Invariants & Rules

When submitting changes, adhere strictly to these principles:

1. **Never synthesize or fabricate a quota**: If a provider does not expose a real limit or remaining count, return `.unavailable(...)`. Do not synthesize fake limits (e.g. `?? 500` or `?? 100%`).
2. **Never treat failure as healthy**: HTTP status checks must precede parsing; a decode failure must map to `.badResponse` or an appropriate unavailable state.
3. **`consumptionFraction` is `Double?`**: `nil` indicates "no denominator" (not 0.0 or 1.0).
4. **Hermetic tests**: All network calls in tests must use `QuotaHTTP.$session.withValue(...)` and verify stubs were hit.
5. **No credential leaks**: Credentials must remain in secure Keychain storage and never be serialized into error logs or user-facing strings.
6. **Zero warnings**: All code must compile cleanly with `-warnings-as-errors`.

---

## Development & Testing Workflow

### Prerequisites
- macOS 15.0+ (Sequoia)
- Swift 6.0+ / Xcode 16.0+

### Build & Run Tests
```bash
# Build with zero-warning tolerance
swift build -Xswiftc -warnings-as-errors

# Run full test suite in parallel
swift test -c debug --parallel
```

---

## Pull Request Guidelines

1. Fork the repository and create a feature branch (`git checkout -b feat/my-feature`).
2. Ensure all tests pass locally before submitting.
3. Keep commits atomic and descriptive following Conventional Commits (e.g., `feat:`, `fix:`, `docs:`, `test:`).
4. Open a pull request against the `main` branch.
