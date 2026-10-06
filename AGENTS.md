# AGENTS.md

## Tone

Write every reply in `/i-have-adhd` tone: the action or the answer comes first,
multi-step work is numbered, and state lands in the repo rather than in the
conversation.

Load the skill when it is there for the full detail. It sits at
`~/.agents/skills/i-have-adhd`, outside this repo and outside `skills-lock.json`,
so a fresh clone does not have it and the line above has to stand alone.

## Standards

While writing code, follow [`CODING_STANDARDS.md`](CODING_STANDARDS.md).

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
