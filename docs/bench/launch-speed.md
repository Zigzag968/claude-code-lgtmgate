# Launch speed bench

## Why
- Launch time is linear in the characters the Lead pastes: about 2.6 s per 1000 characters.
- Target 10 s, aim 5 s.
- Budget: at most 2048 bytes at the plan launch, flat from 4 KB to 60 KB of project specifics.
- Epic #528, slice P-01 (#527) measures and bounds; references and the expansion hook are #520.

## Trees
- Synthetic project contexts of 4k, 22k and 60k come from a seeded generator, never from a real repo.
- Build one: `node scripts/gen-launch-fixtures.cjs --tree <directory> --size 4k|22k|60k`.
- Check the generator: `node scripts/gen-launch-fixtures.cjs --check` (shares, total, config size, non-ASCII, determinism).
- Nothing generated is committed.

## Measure
- Bytes of a launch: `node scripts/runtime/launch-args.cjs --root <tree> --ref origin/main --stage plan | wc -c`.
- Stages: `plan`, `dev`, `review`; modes: `full` (today's whole `args`), `ref` (refused until #520).
- The CI guard `launch-bytes` prints six lines (plan and review, three sizes) and fails on `UP`.

## Trial protocol
- Factors: sizes (4k, 22k, 60k) x variants (`full`, `ref`) x reps (3 per cell).
- Per trial: launch with `dryRun` on, then with the resume flag on a finished run, and record the wall time.
- Record one row per trial in `launch-speed.json`; never edit a past row.
- The bench confirms the guard; it does not replace it.

## Data file
- `launch-speed.json`: `fields` (column names) and `runs` (rows, in the order of `fields`).
- Fields: `size`, `variant`, `rep`, `seconds`, `outputTokens`, `chars`, `resume`, `dryRun`, `firstRunAgentCalls`, `agentCalls`.
- `runs` is empty in the PR that adds the bench; the trials are recorded afterwards.

## Budget switch
- `LAUNCH_BYTES_BUDGET=off|on`, default `off`; `on` once #520 lands.
- Applies to `stage=plan` in mode `ref` only: each size at most 2048 bytes, spread between 4k and 60k at most 64 bytes.
- Mode `full` has no budget; #520 extends it to `stage=review` with P-07.

## Baseline
- `scripts/launch-bytes-baseline.json` holds the measured bytes; it is never raised to turn a run green.
- The only exception is a `"debt": "DEBT(#N)"` key with the issue that pays it back.
