# Scope Exhaustion Execution Concept V0.1

Status: implemented local execution concept for owned PetClinic autonomous refactor scope drain.

## Objective

Run the governed PetClinic autonomous refactor process until the currently authorized local scope has no remaining auto-patchable candidates.

This concept closes the gap between a single bounded wave and true scope exhaustion. A wave remains useful for PR publication, but it is not the unit that proves the scope is empty. The scope-drain unit is a repeated local lease segment on the current branch.

## Execution Model

Entry point:

```powershell
.\threshold\scripts\run-until-scope-exhausted.ps1
```

The runner:

- requires a clean worktree before each segment;
- starts a fresh local lease on the current branch;
- generates a candidate pocket from the current HEAD;
- applies pre-authorized scope expansion tiers when the current tier has too few auto-patchable candidates;
- commits lease and candidate-pocket governance artifacts;
- runs one governed slice at a time until the segment reaches `ready_no_candidates_verified` or `budget_exhausted_verified`;
- refreshes and commits the candidate pocket after each slice;
- records terminal source-head evidence for every segment;
- starts another segment after budget exhaustion;
- stops only when fresh discovery at the maximum authorized scope tier yields no auto-patchable candidates.

## Deliberate Boundaries

The scope drain is local-only by default. It does not push, create or update a PR, merge, release, deploy, alter dependencies, change `pom.xml`, or mutate upstream state.

PR and merge lifecycle remain outside this runner unless another explicitly authorized workflow invokes them. This prevents a local candidate-exhaustion loop from silently becoming repository publication authority.

## Terminal States

`scope_exhausted_verified` means:

- the current branch is clean;
- the final segment has terminal state `ready_no_candidates_verified`;
- candidate discovery was refreshed from the terminal source/evidence head;
- every configured scope expansion tier was exhausted or unnecessary;
- the final candidate pocket contains zero auto-patchable candidates above the configured score threshold.

`budget_exhausted_verified` is not final for the whole scope. It only means the current segment spent its local budget. The runner starts a new segment unless the maximum segment count is reached.

## Known Non-Claims

- No public readiness claim.
- No public correctness claim.
- No public security or compliance claim.
- No upstream interaction.
- No merge authority.
- No release or deploy authority.
