# Desktop Dashboard Widget + API Balances (personal fork)

This fork adds a **movable desktop dashboard window** on top of the stock menu-bar popover, and a set of
**API balance / billing cards**. It also **removes the PostHog telemetry** the upstream app ships with.

## What changed

1. **Telemetry removed.** The `PostHog` dependency and the whole `Telemetry*`/opt-out surface are gone
   (`Package.swift`, `Services/Telemetry.swift`, `Stores/TelemetryRecorder.swift`,
   `Stores/TelemetryStore.swift`, plus the `AppContainer`/`SettingsScreen` wiring). Nothing about your
   usage is sent anywhere. Provider calls still go only to each provider's own API with your own creds.

2. **Desktop widget** (`Sources/OpenUsage/DesktopWidget/`). A borderless, movable `NSPanel`
   (`DesktopWidgetWindowController`) shown on launch that hosts `DesktopDashboardView`:
   - **AI Coding** — Claude Code + Codex, from the same `WidgetDataStore` the popover uses.
   - **API Balances & Billing** — the cards below.
   Drag it anywhere; it remembers its position, joins all Spaces, and never steals focus. Toggle
   "keep on top" with the pin button. Re-open it from the menu-bar icon's right-click menu
   ("Show Desktop Widget"). The menu bar stays as a secondary control.

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
day, so the card refreshes every 6 hours instead of every few minutes.

[gcp-export]: https://cloud.google.com/billing/docs/how-to/export-data-bigquery

## Building

```sh
bash script/build_and_run.sh          # build + ad-hoc sign + launch (dev bundle id, isolated settings)
bash script/build_and_run.sh build    # build only → dist/OpenUsage.app
```

No paid Apple Developer account is required for local use (ad-hoc signing).
