# Contributing to OpenUsage

OpenUsage accepts contributions through an approved-issue workflow. Read this entire document before opening a PR.

## Philosophy

OpenUsage is highly opinionated. It focuses on clean design, fast performance, and a great user experience. The feature set is intentionally limited to core functionality: tracking AI coding subscription usage, nothing more. Contributions that try to expand that scope, add unnecessary complexity, or compromise the UX will be closed.

If you're unsure whether your idea fits, open an issue first. External pull requests without a linked approved issue are closed by the maintainer-run gatekeeper automation.

## Ground Rules

- No feature creep. If it's not about usage tracking, it doesn't belong here.
- External PRs require an open issue approved by a maintainer with the `status:approved` label before review.
- No approved issue, no review. PRs without an approved issue are closed by the maintainer-run gatekeeper automation.
- No AI-generated commit messages. Write your own.
- AI-assisted issues and PRs must say so. Do not imply work was written fully by a human if an AI agent generated or materially shaped it.
- You must be able to explain your changes in plain human words.
- Test your changes. If it touches UI, include before/after screenshots.
- Keep it simple. Don't over-engineer.
- One PR per concern. Don't bundle unrelated changes.
- Match the existing design language. OpenUsage has a specific look and feel — [AGENTS.md](AGENTS.md) documents the display conventions.

## License Agreement

By submitting a pull request, you agree that your contribution is licensed under the [MIT License](LICENSE) that covers this project.

## How to Contribute

### Fork and PR workflow

1. Fork the repo
2. Open an issue describing the change you want to make
3. Wait for a maintainer to approve the issue with `status:approved`
4. Create a branch (`feat/my-change`, `fix/some-bug`, etc.)
5. Make only the approved change
6. Run `swift build` and `swift test` to verify nothing is broken
7. Open a PR against `main` and link the approved issue

External PRs that skip the approved-issue step are closed without review. Maintainers and collaborators may open PRs directly.

### Add a provider

Each provider is a small Swift module under `Sources/OpenUsage/Providers/<Name>/` that conforms to `ProviderRuntime`: an auth store reads credentials already on the user's machine, a usage client calls the provider's API, and a mapper normalizes the response into metric lines. See [docs/adding-a-provider.md](docs/adding-a-provider.md) for the full walkthrough (and [docs/architecture.md](docs/architecture.md) for how the pieces fit together).

1. Open a provider issue first
2. Include demand evidence, usage-data proof, auth/API feasibility, and why this provider belongs in a selective app
3. Wait for a maintainer to approve the issue with `status:approved`
4. Create `Sources/OpenUsage/Providers/<Name>/` and implement `ProviderRuntime`
5. Register the provider in `AppContainer`
6. Add focused tests under `Tests/OpenUsageTests/`
7. Add a provider page in `docs/providers/` (metrics, credential sources, endpoints, troubleshooting)
8. Test it locally with `./script/build_and_run.sh`
9. Open a focused PR with screenshots showing it working

You can also [open an issue](https://github.com/robinebers/openusage/issues/new?template=new_provider.yml) to request a provider without building it yourself.

### Fix a bug

1. Reference the issue number in your PR
2. Describe the root cause and fix
3. Include before/after screenshots for UI bugs
4. Add a regression test if applicable

### Request a feature

Don't open a PR for features without approval first. [Open an issue](https://github.com/robinebers/openusage/issues/new?template=feature_request.yml), explain why it fits core usage tracking, and wait for `status:approved`.

## Pull Request Gate

External pull requests require an open issue approved by a maintainer before review. Approval is represented by the `status:approved` label on the linked issue.

The auto-close behavior is enforced by the maintainer-run OpenUsage PR Gatekeeper Codex automation, not by contributor code or a GitHub Actions policy workflow.

PRs are closed by automation when they:

- Do not link an approved open issue
- Link an issue that is closed, unapproved, rejected, or out of scope
- Change more than 1,000 lines
- Bundle unrelated concerns
- Touch sensitive repo areas without explicit approval in the issue
- Add a provider without demand evidence and feasibility proof
- Add visual changes without before/after screenshots
- Omit a plain-English explanation of what changed and why
- Hide AI assistance or falsely imply human authorship

Sensitive repo areas include `AGENTS.md`, release workflows, signing or notarization setup, Sparkle/update feeds, provider ordering/default layout, dependencies, architecture-level refactors, and new providers.

PRs over 500 changed lines may be labeled `too-large` and held for author action. Split large work into smaller approved PRs.

## Human Explanation and AI Assistance

Every PR must explain the change in plain human words. If a maintainer asks how the code works, the author must be able to answer.

AI-assisted work is allowed, but attribution must be honest. If an AI agent or tool generated or materially shaped an issue, PR, code, tests, docs, or commit message, say so in the PR. Include the tool used, what it generated, what you personally reviewed, and what tests you ran.

PRs with unexplained AI-generated bulk changes, AI-generated commit messages, false attribution, or changes the author cannot explain may be closed without extended review.

## What Gets Accepted

- Bug fixes with clear descriptions
- New providers with an approved issue, demand evidence, feasibility proof, and the existing provider architecture
- Documentation improvements
- Performance improvements with benchmarks
- Accessibility improvements

## What Gets Rejected

- Features that expand the scope beyond usage tracking
- Changes that compromise speed, simplicity, or the existing UX
- PRs without testing evidence
- Code with no clear purpose or explanation
- Cosmetic-only changes without prior discussion
- External PRs without an approved issue
- PRs that hide AI assistance or cannot be explained by the author

## Code Standards

- Swift 6 with strict concurrency, built with SwiftPM (no Xcode project)
- Follow existing patterns in the codebase — [AGENTS.md](AGENTS.md) is the engineering contract
- User-visible behavior changes must update the matching `docs/` page(s) in the same PR
- UI copy is plain language and sentence case
- No new dependencies without justification

## Maintainers

- [@robinebers](https://github.com/robinebers) (lead)
- [@validatedev](https://github.com/validatedev)
- [@davidarny](https://github.com/davidarny)

All PRs require approval from at least 2 maintainers before merging.
Release tags (`v*`) are owner-managed and can only be created by [@robinebers](https://github.com/robinebers).

## Questions?

Open a [bug report](https://github.com/robinebers/openusage/issues/new?template=bug_report.yml) or [feature request](https://github.com/robinebers/openusage/issues/new?template=feature_request.yml) using the issue templates.
