# frugalbar — Track AI usage & dev limits

Native macOS menu bar app that monitors real-time API quota across 7 AI and developer services.

## Project structure

```
frugalbar/
├── .github/workflows/quotabar-ci.yml   # CI: Swift build + test
├── QuotaBar/                            # Swift package (macOS 15+, Swift 6)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── QuotaBarCore/                # Domain models, providers, engine, keychain
│   │   ├── QuotaBarUI/                  # SwiftUI popover, components, settings
│   │   └── QuotaBarApp/                 # NSApplication + MenuBarExtra entry point
│   └── Tests/
│       ├── QuotaBarCoreTests/           # Unit tests for models, providers, engine
│       └── QuotaBarUITests/             # Unit tests for UI components
└── prototype/                           # (legacy) AI Studio prototype
```

## Quick start

```bash
cd QuotaBar
swift run
```

## Build & test

```bash
swift build
swift test --parallel
```

## QuotaBar providers

| Provider | Data source | Metric |
|----------|-------------|--------|
| OpenRouter | `GET /api/v1/auth/key` | USD credit balance |
| GitHub REST | `GET /api/rate_limit` | req/hr remaining |
| GitHub GraphQL | `GET /api/rate_limit` | pts/hr remaining |
| GitHub Copilot | `GET /copilot_internal/v2/token` | Subscription tier |
| Claude | — (no public API) | `.unsupported` banner |
| Gemini | `GET /v1beta/models` | req/day estimate |
| OpenCode Go | `GET /api.opencode.ai/v1/usage` | Units remaining |

## Requirements

- macOS 15+
- Swift 6.0+
- API keys configured via Settings UI, Keychain, or CLI discovery (e.g. `gh auth token`)
