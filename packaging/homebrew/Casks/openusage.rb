# Source-of-truth Homebrew cask for OpenUsage.
#
# This file is the canonical definition the release pipeline copies/derives from. On every STABLE
# release, .github/workflows/release.yml computes the DMG's real sha256 and rewrites `version` and
# `sha256` below, then pushes the result to the `robinebers/homebrew-tap` repo (and, soft-fail, opens
# a bump PR against the official Homebrew/homebrew-cask). The `sha256` value here is a placeholder:
# it must be the 64-hex-char digest of the published DMG for `brew install --cask` to succeed, so the
# automation overwrites it per release. Do not rely on the literal value committed here.
#
# See packaging/homebrew/README.md for the owner steps that can't be automated (creating the tap repo
# and the secrets, and fixing the stale official cask).
cask "openusage" do
  version "0.7.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # replaced per-release by release.yml

  url "https://github.com/robinebers/openusage/releases/download/v#{version}/OpenUsage-#{version}.dmg",
      verified: "github.com/robinebers/openusage/"
  name "OpenUsage"
  desc "AI usage tracker for Cursor, Claude Code, Codex, Copilot and more"
  homepage "https://www.openusage.ai/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "OpenUsage.app"

  zap trash: [
    "~/Library/Application Support/com.robinebers.openusage",
    "~/Library/Caches/com.robinebers.openusage",
    "~/Library/HTTPStorages/com.robinebers.openusage",
    "~/Library/Preferences/com.robinebers.openusage.plist",
    "~/Library/Saved Application State/com.robinebers.openusage.savedState",
    "~/Library/WebKit/com.robinebers.openusage",
  ]
end
