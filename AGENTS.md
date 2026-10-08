# AGENTS.md

The rules for this repo are in [CLAUDE.md](CLAUDE.md), and they bind every
agent, whatever its vendor. Read it first, whole. This file only points to it,
so each rule is stated once.

Why this file exists: vibe (mistral) loads a trusted dir's `AGENTS.md`, never
`CLAUDE.md` (spec 110 T005). The fleet's global rules reach vibe as
`~/.vibe/AGENTS.md`, rendered by spool-install `--fleet` (step
`csi-spl-orc/src/bash/features/spool-install/steps/y8-vibe-agents.sh`) from the
same parts as `~/.claude/CLAUDE.md`.
