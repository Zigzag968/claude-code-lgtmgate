# Vision
The solo Product Engineer ships every idea worth shipping and trusts `main` by reading proofs, not diffs.
- **For whom**: the solo Product Engineer: more ideas than they can code, delegates the code to agents, works alone.
- **Problem**: trusting an agent's PR today means reading its diff, the very work the agent was meant to save.
- **Promise**: done is a merge-ready PR, from a labelled issue, whose every acceptance item is proven, on any GitHub repo.
- **Merge ladder**: today the human merges every PR; a change class with a measured clean record earns merging on its own.
## Principles, ranked (the higher one wins a conflict)
1. Proof over autonomy: every acceptance item is proven, even when that costs a human step.
2. Autonomy over cost: one fewer human intervention is worth more tokens.
3. Cost over thoroughness: tokens per PR stay bounded; the model judges, it never does a script's job.
- Never traded: neutrality over convenience; nothing stack- or repo-specific is imposed on a consumer.
## Non-goals
- Multi-human roles and permissions: the user works alone, so roles would be cost without a user.
- Forges other than GitHub: one forge proven end to end before a second.
## Success signals
- The share of runs that reach `ready` without escalation or manual relaunch.
- Regressions that escape: bugs introduced by a merged PR and found later.
## How agents use this
- Sam's plan names the principle it trades off; Morgan signals a conflict and never blocks on it.
- The Lead names the principle in any escalation that trades one off.
