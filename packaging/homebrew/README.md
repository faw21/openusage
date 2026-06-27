# Homebrew Distribution

OpenUsage ships through two Homebrew channels:

1. **The official `Homebrew/homebrew-cask`** — `brew install --cask openusage`. This is the discoverable,
   default channel for the latest **stable** release. (Homebrew/homebrew-cask does **not** accept
   pre-releases, so betas never go here.)
2. **A personal tap, `robinebers/homebrew-tap`** — `brew install --cask robinebers/tap/openusage`.
   This is ours to control: it can carry betas, ship updates the same hour a release is cut (no
   upstream review queue), and host future OpenUsage CLI tools or formulae.

`Casks/openusage.rb` in this directory is the **source of truth**. The release workflow derives the
per-release cask (correct `version` + `sha256`) from it and publishes to both channels.

---

## Current state (why this exists)

OpenUsage already exists in the official `Homebrew/homebrew-cask`, but the merged cask is **stale** — it
still points at the dead **Tauri 0.6.28** edition:

- per-arch DMG download URLs (the Swift edition ships a single universal `OpenUsage-<version>.dmg`),
- bundle id `com.sunstory.openusage` (the Swift edition is `com.robinebers.openusage`),
- `depends_on macos: :monterey` (the Swift edition requires macOS 15 / Sequoia).

The fix is to replace that cask's body with the one in `Casks/openusage.rb` (see "Fix the official
cask" below).

---

## Owner steps that cannot be automated from this repo

These touch repos and secrets outside `robinebers/openusage`, so a maintainer must do them once by hand.

### 1. Create the tap repo

Homebrew requires the repo name to be exactly `homebrew-tap` so that `brew tap robinebers/tap` resolves
to it. Run (the **maintainer** runs this, not CI):

```sh
gh repo create robinebers/homebrew-tap \
  --public \
  --description "Homebrew tap for OpenUsage (stable, betas, and CLI tools)"
```

Then seed the layout Homebrew expects:

```
homebrew-tap/
  Casks/        # app casks (openusage.rb lives here)
  Formula/      # future CLI tools / formulae
  README.md
```

Seed it with the current cask so the first `brew install` works before the next release:

```sh
git clone https://github.com/robinebers/homebrew-tap
cd homebrew-tap
mkdir -p Casks Formula
cp /path/to/openusage/packaging/homebrew/Casks/openusage.rb Casks/openusage.rb
# fill in the real sha256 for the v0.7.0 DMG (see "Computing the sha256" below)
git add . && git commit -m "Add openusage cask" && git push
```

### 2. Create the release secrets

The release workflow needs two tokens (Settings → Secrets and variables → Actions on
`robinebers/openusage`):

| Secret | What it is | Used for |
| --- | --- | --- |
| `HOMEBREW_TAP_TOKEN` | A fine-grained PAT with **Contents: read & write** on `robinebers/homebrew-tap` | Push the bumped cask to the tap. |
| `HOMEBREW_GITHUB_API_TOKEN` | A classic/fine-grained PAT that can fork `Homebrew/homebrew-cask` and open PRs (public-repo scope) | `brew bump-cask-pr` against the official cask. |

Both are optional in the sense that the workflow tolerates a missing token (the corresponding step
warns and is skipped / soft-fails) so a release is never blocked — but the cask won't update until they
exist.

### 3. Fix the official `Homebrew/homebrew-cask` entry (one-time)

The first stable bump may fail because the existing cask body is the stale Tauri one and the auto-bump
only edits `version`/`sha256`/`url`. Do the structural fix once by hand:

```sh
brew bump-cask-pr openusage   # or edit the cask directly in a homebrew-cask fork
```

Replace the cask body with the contents of `Casks/openusage.rb` here (Swift edition): single universal
`OpenUsage-<version>.dmg` URL, `depends_on macos: ">= :sequoia"`, and the
`com.robinebers.openusage` zap paths. After that one-time correction, `brew bump-cask-pr --version`
from CI keeps it current.

---

## Computing the sha256

The cask's `sha256` is the digest of the published DMG:

```sh
# from a built DMG
shasum -a 256 dist/OpenUsage-0.7.0.dmg | awk '{print $1}'

# or against a published release asset
curl -fsSL https://github.com/robinebers/openusage/releases/download/v0.7.0/OpenUsage-0.7.0.dmg \
  | shasum -a 256 | awk '{print $1}'
```

The release workflow does exactly this on the built DMG and writes the result into the cask before
pushing. The placeholder `sha256` committed in `Casks/openusage.rb` is **not** a valid digest — it is
overwritten per release.

---

## Smoke test

After the tap exists and a release has shipped:

```sh
brew tap robinebers/tap
brew install --cask openusage          # once the official cask is fixed
# or, explicitly from the tap:
brew install --cask robinebers/tap/openusage
```

`brew style` / `brew audit` validate the cask, but note they only run cleanly against a cask **inside a
real tap** (`brew audit openusage` after `brew tap`), not against the loose source-of-truth file here.
Running `brew style` on this standalone file reports a generic `FrozenStringLiteralComment` offense that
does **not** apply to cask files once they live in a tap's `Casks/` directory — ignore it.
