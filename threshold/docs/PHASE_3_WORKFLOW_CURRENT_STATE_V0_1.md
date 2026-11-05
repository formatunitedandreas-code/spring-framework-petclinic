# Phase 3 Workflow Current State v0.1

## Scope

This readout fixes the current Phase 3 workflow boundary at the repository state after PR #177:

- main head: `8ff957c25ac2abcc202d713d57a102fec6b1bb70`
- merged Phase 3 delta range: PR #175 through PR #177
- active unpublished extension lane: `codex/petclinic-semantic-workflow-lane`

The Phase 3 main workflow and the Semantic Twin workflow are related, but they are not the same lane.

## Phase 3 Main Workflow

The workflow merged into `main` is the candidate-oriented governed refactoring lane.

Primary scripts:

- `threshold/scripts/discover-candidates.ps1`
- `threshold/scripts/start-lease.ps1`
- `threshold/scripts/run-next-slice.ps1`
- `threshold/scripts/run-next-batch.ps1`
- `threshold/scripts/run-until-scope-exhausted.ps1`
- `threshold/scripts/complete-slice.ps1`
- `threshold/scripts/record-receipt.ps1`
- `threshold/scripts/test-current-governance-consistency.ps1`
- `threshold/scripts/test-pr-governance.ps1`

Primary state and evidence:

- `threshold/candidate-pocket/current.json`
- `threshold/leases/current.yaml`
- `threshold/lease-state/current-run.json`
- `threshold/receipts/*.json`
- `threshold/attestations/receipt-chain.json`
- `threshold/kgs/capability-kg.json`
- `threshold/kgs/fidelity-kg.json`

Current terminal evidence:

- terminal state: `ready_no_candidates_verified`
- candidate pocket role: terminal source-head evidence
- candidate pocket count: 84 held candidates
- auto-patchable contract: 16 candidate classes
- batch lane: `comment_wrap_cleanup`

This lane is suitable for conservative candidate execution and scope-drain verification. It is still candidate-class driven.

## Semantic Workflow Extension Lane

The branch `codex/petclinic-semantic-workflow-lane` adds a separate, unmerged Semantic Twin workflow.

Additional commits:

- `f9903149 Add PetClinic semantic workflow lane`
- `541d01bb Harden PetClinic semantic workflow gates`

Additional workflow components:

- `threshold/adapters/petclinic-semantic-twin/*.psm1`
- `threshold/policies/semantic-twin-v0.1.yaml`
- `threshold/policies/target-twin-v0.1.yaml`
- `threshold/policies/senior-refactoring-admission-v0.1.yaml`
- `threshold/policies/file-economy-v0.1.yaml`
- `threshold/scripts/materialize-legacy-twin.ps1`
- `threshold/scripts/propose-target-twin.ps1`
- `threshold/scripts/plan-twin-delta.ps1`
- `threshold/scripts/run-next-semantic-workorder.ps1`
- `threshold/scripts/execute-semantic-workorder.ps1`
- `threshold/scripts/verify-twin-outcome.ps1`
- `threshold/scripts/test-semantic-workflow-governance.ps1`

The Semantic Twin lane is currently `plan_only`.

Expected behavior:

- `run-next-semantic-workorder.ps1 -PlanOnly` materializes runtime-only Legacy Twin and Target Twin evidence and produces a PlanOnly delta readout.
- `run-next-semantic-workorder.ps1` without `-PlanOnly` stops with `stop_authority_missing` until SeniorRefactoringGovernor admission is implemented.
- `run-next-slice.ps1` rejects `semantic-workorder:*` and `twin-delta:*` IDs so the legacy candidate executor cannot execute semantic workorders.
- `threshold/runtime/` is ignored and must not be published.

## Workflow Boundary

The merged Phase 3 workflow remains the source of truth for current autonomous candidate execution.

The Semantic Twin lane is a forward-compatible workflow extension and must be merged separately from product refactoring runs.

Do not mix these in one product PR:

- Semantic workflow policies or scripts
- product Java refactorings
- regenerated candidate pockets
- mutable lease state
- full KG snapshots
- runtime twin snapshots

## Current Publication Status

Safe merge sequence:

1. Keep `main` at the merged Phase 3 state from PR #175 through PR #177.
2. Publish the Semantic Twin lane as a governance-only PR.
3. Keep the PR at the explicit governance merge-authority holdpoint until authority is granted.
4. After merge, run Owner Search and Wave 184 replays through the Semantic lane as separate evidence PRs.

Current required holdpoint:

- `test-pr-governance.ps1 -BaseRef main` must fail for governance-policy PRs unless explicit merge authority is present.

Current non-goal:

- No automatic merge, release, deploy, or product refactoring execution is introduced by the Semantic Twin lane.

## Verification Commands

Expected green checks on the Semantic Twin branch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File threshold/scripts/test-semantic-workflow-governance.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File threshold/scripts/run-next-semantic-workorder.ps1 -PlanOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File threshold/scripts/test-current-governance-consistency.ps1
git diff --check HEAD
```

Expected hold checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File threshold/scripts/run-next-semantic-workorder.ps1
```

Expected result:

```text
stop_authority_missing
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File threshold/scripts/test-pr-governance.ps1 -BaseRef main
```

Expected result for governance-policy PRs without merge authority:

```text
Threshold governance policy/authority change requires explicit merge authority.
```
