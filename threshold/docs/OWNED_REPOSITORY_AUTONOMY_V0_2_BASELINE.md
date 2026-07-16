# Owned Repository Autonomy v0.2 Baseline

Status: baseline inventory only, non-authorizing.

This document records the pre-migration state for the Threshold PetClinic owned-repository autonomy v0.2 work. It does not change candidate discovery, execution, validation, publication, pull requests, merge behavior, release behavior, or deployment behavior.

## Git Context

- Repository: `C:\dev\spring-framework-petclinic`
- Baseline branch: `threshold-governance-autonomy-p0-baseline`
- Baseline head: `0dc1bb98595ef20de51ae7478f79d32c82d86a30`
- Base reference observed before P0: `origin/main`
- Observed `origin/main` head: `d039ca6fe980313d93c5945de2729c015e399d48`
- Worktree before P0 edits: clean
- Source wave inherited into this branch: `threshold-governed-refactor-demo-113`

## In-Flight Run Status

The legacy run state exists at `threshold/lease-state/current-run.json`.

- Run branch recorded in state: `threshold-governed-refactor-demo-113`
- Run terminal state: `ready_no_candidates_verified`
- Candidates processed: `1`
- Commits created: `1`
- Remaining candidate budget: `4`
- Remaining commit budget: `4`
- Last source commit recorded by run state: `1234132549a442f922f31a74d2ab79b1bc9569b4`
- Last receipt: `threshold/receipts/src-main-java-org-springframework-samples-petclinic-model-owner-java-model-readability-cleanup-tostring-1234132549a4.json`

This is terminal enough for P0 inventory work. Any future runtime-state format migration must still stop if `terminalState` is `active`.

## Tracked Mutable Runtime Artifacts

The following mutable runtime-style files are currently tracked:

- `threshold/leases/current.yaml`
- `threshold/lease-state/current-run.json`
- `threshold/candidate-pocket/current.json`

Known baseline mismatch:

- `threshold/candidate-pocket/current.json` records `branch=threshold-governed-refactor-demo-108`.
- The current branch for this baseline is `threshold-governance-autonomy-p0-baseline`.
- The terminalized run branch is `threshold-governed-refactor-demo-113`.

This mismatch is intentionally recorded by P0 instead of being normalized.

## Runtime Governance Path Definitions

Runtime governance paths are currently duplicated across scripts:

- `threshold/scripts/run-next-slice.ps1`
- `threshold/scripts/complete-slice.ps1`
- `threshold/scripts/validate-slice.ps1`
- `threshold/scripts/start-next-wave.ps1`
- `threshold/scripts/start-next-wave-cycle.ps1`
- `threshold/scripts/start-lease.ps1`
- `threshold/scripts/sync-lease-state.ps1`
- `threshold/scripts/discover-candidates.ps1`
- `threshold/scripts/record-receipt.ps1`
- `threshold/scripts/preflight.ps1`
- `threshold/scripts/expand-scope.ps1`

The v0.2 migration should centralize this into one runtime module before changing the runtime-state format.

## Candidate Class Inventories

Candidate class authority and capability are currently distributed across:

- Lease allowlist: `threshold/leases/current.yaml`
- Gate allowlist: `threshold/gates/auto-patchable-candidate-classes.json`
- Discovery emitters: `threshold/scripts/discover-candidates.ps1`
- Executor switch: `threshold/scripts/run-next-slice.ps1`
- Batch mode: `threshold/scripts/run-next-batch.ps1`

P0 records this as a duplication finding. It does not change the lists.

## Publication And Merge Behavior

`threshold/scripts/start-next-wave.ps1` currently contains local execution, final validation, branch push, pull-request creation, PR check watching, readiness assertion, and merge execution in one launcher path.

Current lease terminal boundary records:

- `draftPrAllowed: true`
- `mergeAllowed: false`

P0 does not alter this behavior. Later slices should separate publication from merge using grant-bound phases.

## Non-Claims

- This baseline is not execution authority.
- This baseline is not publication authority.
- This baseline is not merge authority.
- This baseline is not release or deploy authority.
- This baseline does not claim behavior preservation for future migration slices.
- This baseline does not normalize stale runtime state.
