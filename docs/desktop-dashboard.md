# Desktop Dashboard Widget + API Balances (personal fork)

This fork adds a **movable desktop dashboard window** on top of the stock menu-bar popover, and a set of
**API balance / billing cards**. It also **removes the PostHog telemetry** the upstream app ships with.

## What changed

1. **Telemetry removed.** The `PostHog` dependency and the whole `Telemetry*`/opt-out surface are gone
   (`Package.swift`, `Services/Telemetry.swift`, `Stores/TelemetryRecorder.swift`,
   `Stores/TelemetryStore.swift`, plus the `AppContainer`/`SettingsScreen` wiring). Nothing about your
   usage is sent anywhere. Provider calls still go only to each provider's own API with your own creds.

2. **"API Balances & Billing" section** in the menu-bar popover, below the provider widgets
   (`Views/DashboardContentView.swift`, cards drawn by `DesktopWidget/BalanceCardView.swift`). An early
   version of this fork floated the cards in a always-on-screen `NSPanel`; that window was dropped
   because foreground apps covered it — the cards now live in the popover you already open by clicking
   the menu-bar icon.

3. **Balance subsystem** (`Sources/OpenUsage/Balances/`). Each `BalanceSource` owns its own key lookup,
   HTTP call, and graceful degradation, and returns a `BalanceCard`. `BalanceStore` fans them out
   concurrently, each on its own cadence.

## Configuring keys

Keys/config live in `~/.config/openusage/<name>.json` as `{"apiKey":"…"}` (env vars also work). These
files are **outside the repo** and are never committed.

| Card | File / env | What it shows | Notes |
|------|------------|---------------|-------|
| OpenRouter | `openrouter.json` / `OPENROUTER_API_KEY` | Credit balance + month-to-date spend | Regular key. |
| OpenAI | `openai.json` / `OPENAI_ADMIN_KEY` | Month-to-date spend | Needs an **admin key** (`sk-admin-…`); no balance API exists. |
| Anthropic | `anthropic.json` / `ANTHROPIC_ADMIN_KEY` | Month-to-date spend | Needs an **admin key** (`sk-ant-admin01-…`); no balance API exists. |
| Perplexity | — | Not available | Perplexity has **no** balance/billing API (verified); credits are console-only. |
| Webshare | `webshare.json` / `WEBSHARE_API_KEY` | Bandwidth used / limit + reset date | `Authorization: Token …`. |
| Google Cloud | `gcp.json` | Current-month spend | See below — needs a BigQuery billing export. |

Gemini is intentionally **not** shown: it has no balance API and its paid usage is billed through GCP.

## GCP current-month spend

There is no API-key path for GCP billing. The only reliable current-month figure comes from a
**BigQuery billing export**. Once you've [enabled billing export to BigQuery][gcp-export], point the card
at the export table:

```json
// ~/.config/openusage/gcp.json
{ "bqTable": "your-project.billing_export.gcp_billing_export_v1_XXXXXX" }
```

Requirements: the Cloud SDK `bq` on `PATH` (or set `"bqBinary"`), and
`gcloud auth application-default login`. Querying a billing-export table scans only a few MB, well inside
BigQuery's 1 TB/month free tier, so it's effectively free — but billing data only updates a few times a
day, so the card refreshes every 3 hours instead of every few minutes, and the manual refresh button
skips it (each reload spawns a `bq` subprocess for numbers that barely move).

[gcp-export]: https://cloud.google.com/billing/docs/how-to/export-data-bigquery

## Building

```sh
bash script/build_and_run.sh          # build + ad-hoc sign + launch (dev bundle id, isolated settings)
bash script/build_and_run.sh build    # build only → dist/OpenUsage.app
```

No paid Apple Developer account is required for local use (ad-hoc signing).

## Running the tests on a Command Line Tools toolchain

`swift test` needs XCTest, which only ships inside Xcode — and the installed Xcode's Swift is older than
the package's tools version, so it can't build the package either. Build the test bundle with the CLT
compiler while borrowing Xcode's XCTest, then run the bundle with Xcode's `xctest` agent:

```sh
XC=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
swift build --build-tests \
  -Xswiftc -I -Xswiftc $XC/usr/lib -Xswiftc -F -Xswiftc $XC/Library/Frameworks \
  -Xlinker -F -Xlinker $XC/Library/Frameworks -Xlinker -L -Xlinker $XC/usr/lib \
  -Xlinker -rpath -Xlinker $XC/usr/lib -Xlinker -rpath -Xlinker $XC/Library/Frameworks \
  -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/SharedFrameworks
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  .build/arm64-apple-macosx/debug/OpenUsagePackageTests.xctest
```

The one swift-testing file (`Tests/OpenUsageTests/OpenUsageISO8601Tests.swift`) can't compile this way —
the `Testing` module only exists in the older Xcode toolchain — so move it aside for the run if the build
stops there. Everything else (1282 XCTest cases) runs.
