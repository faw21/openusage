# Nearby Macs

OpenUsage can combine machine-local usage from several Macs on the same local network. There is no
cloud account or relay: the Macs find and talk to each other directly.

## Connect two Macs

1. Open **Settings → Nearby Macs** on both computers.
2. Turn on **Share Across Macs**. macOS asks for Local Network permission the first time.
3. When the other Mac appears, click **Connect**.
4. Compare the six-digit code shown on both Macs, then click **Allow** on the receiving Mac.

The connection stays approved until you click **Forget**. Turning Share Across Macs off pauses all
discovery and sharing without forgetting approved Macs.

## What gets combined

OpenUsage adds the usage each computer measures from its own local history:

- Today, Yesterday, and Last 30 Days cost/token totals
- Usage Trend day totals

Account-wide limits such as Session and Weekly are not added. Those values already describe the whole
provider account, so adding the same limit from several Macs would be wrong. They continue to come from
the Mac whose menu bar you are viewing.

Nearby usage updates after each normal or manual refresh. When a Mac leaves the network, its contribution
is removed until it becomes available and syncs again. Remote snapshots are kept only in memory and are
never written into the local provider cache.

## Security and privacy

- Discovery uses Bonjour and is off until you enable it.
- Pairing requires a matching code and approval on the receiving Mac.
- Each approved pair gets its own secret saved in the macOS Keychain.
- Every later refresh authenticates both Macs and encrypts the usage payload.
- Provider credentials, cookies, API keys, and raw log files never leave their Mac.
- No OpenUsage server or other internet service is involved.

If a Mac is lost or no longer trusted, click **Forget** beside it. This deletes that pair's saved key and
stops its data from contributing.
