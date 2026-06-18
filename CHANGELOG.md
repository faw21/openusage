# Changelog

## v0.7.0-beta.8

### New Features
- Split spend into cost/tokens, carry raw metric values (#641, #647) by @robinebers

## v0.7.0-beta.7

### New Features
- Show Codex rate limit resets in the tray and popover ([#638](https://github.com/robinebers/openusage/pull/638)) by @robinebers
- Collapse the footer Customize button into a More menu ([#640](https://github.com/robinebers/openusage/pull/640)) by @robinebers
- Label the pace run-out time as "Limit in 3h 45m" ([#643](https://github.com/robinebers/openusage/pull/643)) by @robinebers
- Show a numeric projection in pace meter tooltips at reset ([#644](https://github.com/robinebers/openusage/pull/644)) by @robinebers

### Bug Fixes
- Resolve npx/npm/pnpm/yarn ccusage runners, not just bunx ([#643](https://github.com/robinebers/openusage/pull/643)) by @robinebers
- Follow nvm alias indirection when locating the ccusage runner ([#643](https://github.com/robinebers/openusage/pull/643)) by @robinebers
- Unify the Codex rate-limit-resets value across tray and popover ([#638](https://github.com/robinebers/openusage/pull/638)) by @robinebers
- Promote a ~0% projected-spare pace meter to red, not amber ([#639](https://github.com/robinebers/openusage/pull/639)) by @robinebers
- Anchor the footer More menu to a flipped view ([#640](https://github.com/robinebers/openusage/pull/640)) by @robinebers
- Guard against a second app instance (duplicate menu-bar icon) ([#637](https://github.com/robinebers/openusage/pull/637)) by @robinebers
- Use a deterministic lowest-PID tie-break in the single-instance guard ([#637](https://github.com/robinebers/openusage/pull/637)) by @robinebers

## v0.7.0-beta.6

### New Features
- Add Reduce Transparency setting for readability ([#629](https://github.com/robinebers/openusage/pull/629)) by @robinebers
- Drop global pin cap, keep two per provider ([#630](https://github.com/robinebers/openusage/pull/630)) by @robinebers

### Bug Fixes
- Only draw card border/frost when Reduce Transparency is on by @robinebers
- Enlarge header provider glyph to match the menu-bar strip by @robinebers

### Chores
- Align README with per-provider pin limit by @robinebers

## v0.7.0-beta.5

### New Features
- Build a universal binary so the app runs natively on both Apple Silicon and Intel Macs by @robinebers
- Support macOS 15 (Sequoia) and later, not only Tahoe ([#623](https://github.com/robinebers/openusage/pull/623)) by @robinebers

### Bug Fixes
- Enlarge provider glyphs in the menu-bar Text strip ([#627](https://github.com/robinebers/openusage/pull/627)) by @robinebers

### Chores
- Drop the unworkable macos-15 CI verify leg ([#623](https://github.com/robinebers/openusage/pull/623)) by @robinebers

## v0.7.0-beta.4

### Bug Fixes
- Show the full version, including the beta tag, in both the updater prompt and the app footer so they match by @robinebers

### Chores
- Add hero screenshot to README by @robinebers

---

### Changelog

**Full Changelog**: [v0.7.0-beta.3...v0.7.0-beta.4](https://github.com/robinebers/openusage/compare/v0.7.0-beta.3...v0.7.0-beta.4)

- [763306b](https://github.com/robinebers/openusage/commit/763306b) fix(version): show the full version (incl. -beta.N) in Sparkle and the app by @robinebers
- [a82e8b3](https://github.com/robinebers/openusage/commit/a82e8b3) docs: add hero screenshot to README by @robinebers

## v0.7.0-beta.3

### New Features
- Port the Tauri debug-logging system to the native app ([#615](https://github.com/robinebers/openusage/pull/615)) by @robinebers

### Bug Fixes
- Fix white flicker on screen switches with an offset pager ([#614](https://github.com/robinebers/openusage/pull/614)) by @robinebers
- Fix Codex/Devin usage bugs ([#612](https://github.com/robinebers/openusage/pull/612)) by @robinebers

### Refactor
- Settings: drop Refresh Every, move Style into Appearance as Menu Style ([#613](https://github.com/robinebers/openusage/pull/613)) by @robinebers
- Remove dead code, fix stale comments, dedupe HTTP status guard ([#619](https://github.com/robinebers/openusage/pull/619)) by @robinebers
- Remove dead code, DRY duplication, hot-path allocations ([#610](https://github.com/robinebers/openusage/pull/610)) by @robinebers

### Chores
- Add rollout guardrails, rename release skill to release-swift, show full version in app ([#621](https://github.com/robinebers/openusage/pull/621)) by @robinebers
- Remove dead self-referential links and screenshot placeholders ([#618](https://github.com/robinebers/openusage/pull/618)) by @robinebers
- Run dev build in place instead of installing a Preview app by @robinebers

---

### Changelog

**Full Changelog**: [v0.7.0-beta.2...v0.7.0-beta.3](https://github.com/robinebers/openusage/compare/v0.7.0-beta.2...v0.7.0-beta.3)

- [c80b034](https://github.com/robinebers/openusage/commit/c80b034) feat(logging): port the Tauri debug-logging system to the native app by @robinebers
- [9c7d95e](https://github.com/robinebers/openusage/commit/9c7d95e) Fix white flicker on screen switches with an offset pager (#614) by @robinebers
- [250b278](https://github.com/robinebers/openusage/commit/250b278) Fix Codex/Devin usage bugs; cut dead code, DRY dup, stale docs by @robinebers
- [da7c69c](https://github.com/robinebers/openusage/commit/da7c69c) Settings: drop Refresh Every, move Style into Appearance as Menu Style by @robinebers
- [524e07e](https://github.com/robinebers/openusage/commit/524e07e) refactor: remove dead code, fix stale comments, dedupe HTTP status guard by @robinebers
- [8bdaf61](https://github.com/robinebers/openusage/commit/8bdaf61) Refactor: remove dead code, DRY duplication, hot-path allocations by @robinebers
- [c44247a](https://github.com/robinebers/openusage/commit/c44247a) chore: add rollout guardrails, rename release skill, show full version by @robinebers
- [6a9645d](https://github.com/robinebers/openusage/commit/6a9645d) docs: remove dead self-referential links and screenshot placeholders by @robinebers
- [0ea6b97](https://github.com/robinebers/openusage/commit/0ea6b97) Run dev build in place instead of installing a Preview app by @robinebers
