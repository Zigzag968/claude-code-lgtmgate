# Vision
## Where we are going (6-12 months)
- Merge without the human: a change class with a measured clean record merges on its own; the human decides one-way doors only.
- Unattended runs: consumer repos deliver issues overnight with no one watching; most runs reach `ready` with no relaunch.
- Product-aligned agents: plans follow each repo's own VISION; the human stops correcting product choices, not just code.
- Self-improving pipeline: every incident becomes a replayed fixture and a fix without the human.
For whom, today: the solo Product Engineer, with more ideas than they can code, who delegates code to agents and reads proofs, not diffs.
## Doctrine, ranked (the higher one wins a conflict)
1. Proof over autonomy: every acceptance item is proven, even when that costs a human step.
2. Autonomy over cost: one fewer human intervention is worth more tokens.
3. Cost over thoroughness: tokens per PR stay bounded; the model judges, it never does a script's job.
- Never traded: neutrality; nothing stack- or repo-specific is imposed on a consumer.
## Non-goals
- Multi-human roles and permissions (the user works alone); forges other than GitHub (one forge proven end to end first).
## Success signals
- The share of runs that reach `ready` without escalation or manual relaunch; regressions that escape a merged PR.
## How agents use this
- Sam's plan names the destination it moves toward and the principle it trades off; Morgan signals a conflict, never blocks on it.
