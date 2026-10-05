# AGENTS.md

## Skills

`.agents/skills/`, pinned by `skills-lock.json` and restored by running
`/setup-matt-pocock-skills`. The directory is gitignored, so a fresh clone
starts with none. `/ask-matt` routes a situation to the right one.

## Checks

`pwsh scripts/test-all.ps1` runs every suite this machine can. `.githooks/` runs
it pre-push and the glossary check pre-commit; neither is active until
`git config core.hooksPath .githooks`.

## Repo docs

- **Issues**: GitHub Issues, via the `gh` CLI. `docs/agents/issue-tracker.md`
- **Triage labels**: `needs-triage`, `needs-info`, `ready-for-agent`,
  `ready-for-human`, `wontfix`. `docs/agents/triage-labels.md`
- **Domain language**: `CONTEXT.md` and `docs/adr/`. `docs/agents/domain.md`
