# Devin

Tracks your Devin quota using the login from the Devin CLI or the Devin app.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | Weekly quota used (falls back to the daily figure when Devin reports no weekly quota) |
| Daily | Daily quota used (hidden when Devin hides the daily quota) |
| Extra Balance | Overage/extra-usage balance in dollars |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Checked in this order — whichever works first wins:

1. Devin CLI credentials: `~/.local/share/devin/credentials.toml` (uses `windsurf_api_key`, and `api_server_url` when present)
2. The Devin app's local state database

If the CLI credentials fail but the app is signed in with a different account, the app's auth is used instead.
An `api_server_url` in the CLI file must be a valid HTTPS URL; OpenUsage reports an invalid credential
file rather than silently sending that key to the default server.

## Troubleshooting

- **"Couldn't read Devin credentials"** — OpenUsage found the CLI credential file or Devin app database but could not read it. Check access to those files, then refresh.
- **"Devin credentials are invalid"** — a stored credential payload is malformed. Run `devin auth login`, or sign in to the Devin app again.
- **"Not logged in"** — run `devin auth login`, or sign into the Devin app, then refresh.
- **Weekly shows the daily figure** — when Devin reports no separate weekly quota, the daily quota is shown in the Weekly row so it stays meaningful.

## Under the hood

Connect RPC `GetUserStatus` on the configured API server (default `server.codeium.com`). Quota percentages arrive as "remaining" and are flipped to "used". No token refresh — a 401/403 switches to the next auth source instead.
