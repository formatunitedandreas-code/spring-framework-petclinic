# PetClinic Typed Adapter Shadow Freeze Review Request v0.1

Date: 2026-07-20
Repository: spring-framework-petclinic
Branch: codex/petclinic-semantic-adapter-hardening
Pre-freeze head: a0a1d1cadaa358a3702b35cab5a637cb95d7a482
Pre-freeze tree: 5a5faa4af4530599302bc2aca16a336796464f85

Threshold Core dependency observed for this adapter freeze:

- Repository: threshold-ai-slim
- Branch: codex/threshold-semantic-maturity-hardening
- Pre-freeze head: a6d6d1cf61c44c3d5dc0f44d330fc77597e71db4
- Pre-freeze tree: 63b30422c2c283641f15db472799947e1a4f67e2

## Senior Classification

Current classification:

```json
{
  "classification": "technically_hardened_shadow_candidate",
  "independentShadowMaturityConfirmed": false,
  "productiveDecisionInstance": false,
  "authorizing": false,
  "publicationReady": false,
  "mergeReady": false
}
```

The PetClinic adapter is technically hardened to consume typed Core publication outcomes and to run non-authorizing observation/readout checks. It is not independently confirmed as shadow-ready and is explicitly not a productive decision instance.

## Freeze Scope

This freeze request covers the PetClinic adapter-governance lane only. PetClinic does not contain a second generic reason, authority or decision engine. It consumes the canonical Threshold Core CLI result and projects legacy stop strings only after typed effect decisions have been evaluated.

The commit that contains this document creates a new head, so any previous review binding is invalidated and must be re-established against the post-commit head captured in the gitignored handoff.

## Review Invalidation Rule

Every new commit on this branch invalidates any prior independent review binding.

Required behavior:

- bind review to exact PetClinic repository, branch, head and tree;
- bind the adapter review to the exact Threshold Core artifact/head used by the validator;
- treat changed PetClinic head, changed PetClinic tree or changed Core artifact digest as `review_invalidated_by_new_commit`;
- require a fresh read-only independent review after every new commit;
- keep `independentReview=false` until that review is complete;
- never infer publication or merge authority from typed audit validity, Somnium status, self-validation, reason labels or local fixtures.

## Read-Only Review Session Request

Requested session:

```json
{
  "sessionType": "independent_read_only_review",
  "requested": true,
  "authorizing": false,
  "allowedEffects": ["observe"],
  "forbiddenEffects": ["localExperiment", "localCommit", "publication", "merge", "releaseDeploy"],
  "reviewDecision": "pending",
  "independentReview": false
}
```

Review focus:

- PetClinic consumes `valid`, `evaluatedHead`, `inputDigest`, `effectDecisions.publication.allowed`, `effectDecisions.publication.failedConstraintIds` and `failedConstraintIds`;
- PetClinic does not decide from `decision`, `reasonCodes`, reason ordering or reason containment;
- `push` maps to publication and `merge` cannot authorize publication;
- post-validator head, branch and tree changes stop the publication path;
- Somnium remains non-authorizing and limited to observe/shadowIntegration as inherited from Core;
- `shadow_ready` is not publication readiness or merge readiness.

## Local Validation

Executed before this freeze request:

- PowerShell parser across `threshold/scripts/*.ps1`
- `threshold/scripts/test-publication-preflight-fixtures.ps1 -BaseRef main -ThresholdCorePath C:\dev\threshold-ai-slim`
- `threshold/scripts/test-publication-toctou-isolated-fixture.ps1`
- `threshold/scripts/test-semantic-workflow-governance.ps1`
- `threshold/scripts/test-pr-governance.ps1 -BaseRef main`
- `threshold/scripts/audit-publication-reason-boundary.ps1 -CheckOnly`
- `threshold/scripts/test-current-governance-consistency.ps1`
- `threshold/scripts/test-kg-governance.ps1`
- `threshold/scripts/test-semantic-correctness.ps1 -BaseRef origin/main`
- `.\mvnw.cmd test` with `JAVA_HOME=C:\Program Files\Java\jdk-17`
- `git diff --check origin/main...HEAD`
- `git diff --stat origin/main...HEAD`
- `git diff --name-status origin/main...HEAD`

## Non-Claims

This request does not approve shadow maturity, publication, merge, release, deploy, product pilot, policy activation, model activation or productive decision use.
