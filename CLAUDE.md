# CLAUDE.md

Standing instructions for Claude Code working in this repo.

## About this repo

A single self-contained static page (`index.html`) visualizing Rolling
Stone's 500 Greatest Albums list, deployed via GitHub Pages. No build
step, no dependencies, no CI.

## Development workflow

Every change to this repo — no exceptions for trivial fixes — follows
this cycle:

1. **Explore & Plan** — read the relevant part of the code, understand
   the current implementation, and sketch an approach before writing code.
2. **Create a GitHub issue** describing the change (`gh issue create`).
3. **Create a branch off `main`**, named `<issue-number>-kebab-summary`
   (e.g. `13-fix-mobile-decade-chart-reset`).
4. **Implement** the change on that branch. If the change is
   user-facing, prepend a new entry to `RELEASE_NOTES` in
   `index.html` (newest first) and bump `CURRENT_VERSION` per
   semver — **patch** for fixes/cosmetic tweaks, **minor** for new
   features, **major** reserved for breaking/redesign changes.
5. **Commit** with a message referencing the issue (e.g.
   `Fix mobile decade chart reset (#13)`).
6. **Push** the branch and **open a PR** with `gh pr create`, with
   `Closes #<n>` in the body so the issue auto-closes on merge.
7. **Stop.** Claude never merges. The user reviews and merges manually
   via GitHub (UI or `gh pr merge`) — always the final gate before
   anything reaches `main` and the live Pages deploy.

## Notes for Claude Code

- Do not enable branch protection, add GitHub Actions, or otherwise
  change repo/org settings without asking first.
- Do not add issue/PR templates unless asked.
- Solo hobby project — keep process lightweight; no required reviewers,
  status checks, or other team-scale ceremony unless explicitly requested.
