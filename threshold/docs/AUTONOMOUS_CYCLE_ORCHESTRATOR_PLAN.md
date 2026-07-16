# Autonomous Cycle Orchestrator Plan

Status: implemented as a fail-closed governance orchestrator.

## Goal

Reduce manual hand-offs between these phases:

- synchronize local `main` with `origin/main`
- run the owned-repository `FullLifecycle`
- detect `ready_no_candidates_on_fresh_wave`
- apply only pre-authorized capability expansions
- publish and merge those expansions in the owned repository
- rerun the wave lifecycle
- return local state to synchronized `main`

## Implemented Entry Point

Use:

```powershell
.\threshold\scripts\start-autonomous-cycle.ps1
```

Safe inspection mode:

```powershell
.\threshold\scripts\start-autonomous-cycle.ps1 -PlanOnly
```

## Capability Registry

The registry lives at:

```text
threshold/capability-backlog/approved-expansions.json
```

It is fail-closed:

- no registry entry means stop
- `enabled=false` means stop
- `status` must be `ready`
- `applyScript` must be under `threshold/scripts/`
- `allowedChangedPaths` is required
- validation commands must pass before commit
- owned repository publication and merge are allowed only through the orchestrator path

## Stop Conditions

The orchestrator stops without mutation or after returning to synchronized `main` when:

- the worktree is dirty
- `origin/main` cannot be fast-forwarded
- the wave lifecycle fails
- no candidates are found and no approved expansion is available
- a capability expansion changes a path outside its allowlist
- validation, CI, PR mergeability, or merge fails

## Non-Claims

- This does not authorize upstream interaction.
- This does not authorize force push.
- This does not authorize release or deploy.
- This does not claim public readiness, correctness, security, or compliance.
