# Command-Line Interface

OpenUsage ships an `openusage` command inside the macOS app. It gives people a compact terminal view
and gives agents and scripts stable JSON without duplicating provider logins or asking for API keys.

```sh
openusage                    # table in a terminal; JSON when piped
openusage claude             # one provider
openusage --json             # always JSON
openusage --table            # always a table
openusage --no-launch        # fail instead of starting the menu-bar app
```

The command uses OpenUsage's loopback-only, read-only local connection. Provider credentials remain in
the menu-bar app and are never returned. If OpenUsage is closed, the bundled command starts it and waits
briefly for usage to become available. Values follow the app's normal refresh and caching rules.

## Installation and Updates

The executable lives at:

```text
/Applications/OpenUsage.app/Contents/Helpers/openusage
```

It is signed and shipped inside every app release, so Sparkle updates it together with the app. The
Homebrew cask can expose that bundled executable on `PATH` with its `binary` artifact; direct-download
users can invoke the full path or symlink it into a directory already on their `PATH`.

This first version is macOS-only. A Linux build would require separating the provider engine from the
AppKit app and replacing macOS-specific credential sources such as Keychain. Keeping that larger
refactor out of the initial CLI avoids two provider implementations drifting apart.

## Agent Usage

When stdout is not a terminal, JSON is automatic:

```sh
openusage | jq '.[] | {providerId, lines}'
openusage codex | jq '.lines[] | select(.type == "progress")'
```

The JSON is the same documented format as the [local HTTP API](local-http-api.md), including
`providerId`, `fetchedAt`, and type-tagged metric lines.
